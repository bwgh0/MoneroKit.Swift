#include <inttypes.h>
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <vector>
#include <string>
#include "helpers.hpp"
#include "wallet2_api.h"
#include <set>
#include <sstream>
#include <cstring>
#include <thread>
#include <iostream>
#include <stdexcept>
#include <mutex>

__attribute__((constructor))
void library_init() {}

// --- Hardware device bridge state ---
//
// wallet2's HIDAPI_DUMMY shim calls these statics to swap byte buffers
// with a host-side transport. For Monero One the host side is the
// Trezor BLE bridge (TrezorBridgeServer + THP channel); the same hooks
// would also serve a Ledger transport.
//
// All state is guarded by s_deviceMutex because wallet2's signing
// thread and the iOS BLE delegate queue both touch it.
static std::mutex s_deviceMutex;
static bool s_stateIsConnected = false;
static bool s_waitsForDeviceSend = false;
static bool s_waitsForDeviceReceive = false;
static std::vector<unsigned char> s_sendToDevice;
static std::vector<unsigned char> s_receivedFromDevice;
static void (*s_ledgerCallback)(unsigned char*, unsigned int) = nullptr;

// All bridge accessors below are wrapped in try/catch and treat
// any exception (allocation failure, mutex error) as "no data" /
// "not connected". These functions are called by wallet2's
// HIDAPI_DUMMY shim from its own C++ code — but if any propagated
// up into a context that doesn't unwind cleanly (e.g. across a
// foreign-function-interface boundary), `std::terminate` would
// abort the app. The host-side BLE transport is failure-tolerant
// (the iOS side observes a timeout and resets the THP channel),
// so dropping a single bridge exchange is strictly safer than
// crashing the wallet process.

bool Monero::Wallet::getStateIsConnected() {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        return s_stateIsConnected;
    } catch (...) { return false; }
}

unsigned char* Monero::Wallet::getSendToDevice() {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        return s_sendToDevice.empty() ? nullptr : s_sendToDevice.data();
    } catch (...) { return nullptr; }
}

size_t Monero::Wallet::getSendToDeviceLength() {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        return s_sendToDevice.size();
    } catch (...) { return 0; }
}

unsigned char* Monero::Wallet::getReceivedFromDevice() {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        return s_receivedFromDevice.empty() ? nullptr : s_receivedFromDevice.data();
    } catch (...) { return nullptr; }
}

size_t Monero::Wallet::getReceivedFromDeviceLength() {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        return s_receivedFromDevice.size();
    } catch (...) { return 0; }
}

bool Monero::Wallet::getWaitsForDeviceSend() {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        return s_waitsForDeviceSend;
    } catch (...) { return false; }
}

bool Monero::Wallet::getWaitsForDeviceReceive() {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        return s_waitsForDeviceReceive;
    } catch (...) { return false; }
}

// Caller must pass a contiguous buffer of at least `len` bytes (or
// nullptr / len=0 to clear). A misformed (data, len) pair would
// trigger an out-of-bounds read inside `vector::assign`; guard
// explicitly so a Swift bug can't corrupt memory here.
void Monero::Wallet::setDeviceReceivedData(unsigned char* data, size_t len) {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        if (data == nullptr || len == 0) {
            s_receivedFromDevice.clear();
            return;
        }
        s_receivedFromDevice.assign(data, data + len);
    } catch (...) {
        // OOM or other failure — leave the buffer in its prior
        // state; wallet2 will time out waiting for a response.
    }
}

void Monero::Wallet::setDeviceSendData(unsigned char* data, size_t len) {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        if (data == nullptr || len == 0) {
            s_sendToDevice.clear();
            return;
        }
        s_sendToDevice.assign(data, data + len);
    } catch (...) { /* see setDeviceReceivedData */ }
}

void Monero::Wallet::setLedgerCallback(void (*sendToLedgerDevice)(unsigned char* command, unsigned int cmd_len)) {
    try {
        std::lock_guard<std::mutex> lock(s_deviceMutex);
        s_ledgerCallback = sendToLedgerDevice;
    } catch (...) { /* mutex lock can throw std::system_error */ }
}

// --- Custom utility statics referenced by wallet2_api.h ---
//
// These are not present in upstream Monero — they were declared in
// our patched wallet2_api.h so the linker needs definitions. Real
// derivation is done elsewhere; these stubs just satisfy the symbol
// table.

std::string Monero::Wallet::bytesToWords(const char* src) {
    return "";
}

std::string Monero::Wallet::generateAddress(const std::string& seed, const std::string& seed_offset, uint32_t accountIndex, uint32_t addressIndex, bool testnet) {
    return "";
}

std::string Monero::Wallet::generateKey(const std::string& seed, const std::string& seed_offset, const bool privateKey, const bool spendKey) {
    return "";
}

const char* vectorToString(const std::vector<std::string>& vec, const std::string separator) {
    // Check if the vector is empty
    if (vec.empty()) {
        return "";
    }

    // Concatenate all strings in the vector
    std::string result;
    for (size_t i = 0; i < vec.size() - 1; ++i) {
        result += vec[i];
        result += separator;
    }
    result += vec.back();  // Append the last string without the separator

    std::string str = result;
    const std::string::size_type size = str.size();
    char *buffer = new char[size + 1];   //we need extra char for NUL
    memcpy(buffer, str.c_str(), size + 1);
    return buffer;
}

const char* vectorToString(const std::vector<uint32_t>& vec, const std::string separator) {
    // Calculate the size needed for the result string
    size_t size = 0;
    for (size_t i = 0; i < vec.size(); ++i) {
        // Calculate the number of digits in each element
        size += snprintf(nullptr, 0, "%u", vec[i]);
        // Add comma and space for all elements except the last one
        if (i < vec.size() - 1) {
            size += separator.size(); // comma and space
        }
    }

    // Allocate memory for the result string
    char* result = static_cast<char*>(malloc(size + 1));
    if (result == nullptr) {
        // Handle memory allocation failure
        return nullptr;
    }

    // Fill in the result string
    char* current = result;
    for (size_t i = 0; i < vec.size(); ++i) {
        // Convert each element to string and copy to the result string
        int written = snprintf(current, size + 1, "%u", vec[i]);
        current += written;
        // Add comma and space for all elements except the last one
        if (i < vec.size() - 1) {
            strcpy(current, separator.c_str());
            current += separator.size();
        }
    }

    return result;
}

const char* vectorToString(const std::vector<uint64_t>& vec, const std::string separator) {
    // Calculate the size needed for the result string
    size_t size = 0;
    for (size_t i = 0; i < vec.size(); ++i) {
        // Calculate the number of digits in each element
        size += snprintf(nullptr, 0, "%llu", vec[i]);
        // Add comma and space for all elements except the last one
        if (i < vec.size() - 1) {
            size += separator.size(); // comma and space
        }
    }

    // Allocate memory for the result string
    char* result = static_cast<char*>(malloc(size + 1));
    if (result == nullptr) {
        // Handle memory allocation failure
        return nullptr;
    }

    // Fill in the result string
    char* current = result;
    for (size_t i = 0; i < vec.size(); ++i) {
        // Convert each element to string and copy to the result string
        int written = snprintf(current, size + 1, "%llu", vec[i]);
        current += written;
        // Add comma and space for all elements except the last one
        if (i < vec.size() - 1) {
            strcpy(current, separator.c_str());
            current += separator.size();
        }
    }

    return result;
}

const char* vectorToString(const std::vector<std::set<uint32_t> >& vec, const std::string separator) {
    // Check if the vector is empty
    if (vec.empty()) {
        return "";
    }

    // Use a stringstream to concatenate sets with commas and individual elements with spaces
    std::ostringstream oss;
    oss << "{";
    for (auto it = vec.begin(); it != vec.end(); ++it) {
        if (it != vec.begin()) {
            oss << separator;
        }

        oss << "{";
        for (auto setIt = it->begin(); setIt != it->end(); ++setIt) {
            if (setIt != it->begin()) {
                oss << separator;
            }
            oss << *setIt;
        }
        oss << "}";
    }
    oss << "}";
    std::string str = oss.str();
    const std::string::size_type size = str.size();
    char *buffer = new char[size + 1];   //we need extra char for NUL
    memcpy(buffer, str.c_str(), size + 1);
    return buffer;
}

// Function to convert std::set<uint32_t> to a string
const char* vectorToString(const std::set<uint32_t>& intSet, const std::string separator) {
    // Check if the set is empty
    if (intSet.empty()) {
        return "";
    }

    // Use a stringstream to concatenate elements with commas
    std::ostringstream oss;
    auto it = intSet.begin();
    oss << *it;
    for (++it; it != intSet.end(); ++it) {
        oss << ", " << *it;
    }

    std::string str = oss.str();
    const std::string::size_type size = str.size();
    char *buffer = new char[size + 1];   //we need extra char for NUL
    memcpy(buffer, str.c_str(), size + 1);
    return buffer;
}

std::set<std::string> splitString(const std::string& str, const std::string& delim) {
    std::set<std::string> tokens;
    if (str.empty()) return tokens;
    size_t pos = 0;
    std::string token;
    std::string content = str;  // Copy of str so we can safely erase content
    while ((pos = content.find(delim)) != std::string::npos) {
        token = content.substr(0, pos);
        tokens.insert(token);
        content.erase(0, pos + delim.length());
    }
    tokens.insert(content);  // Inserting the last token
    return tokens;
}

std::vector<std::string> splitStringVector(const std::string& str, const std::string& delim) {
    std::vector<std::string> tokens;
    if (str.empty()) return tokens;
    size_t pos = 0;
    std::string content = str;  // Copy of str so we can safely erase content
    while ((pos = content.find(delim)) != std::string::npos) {
        tokens.push_back(content.substr(0, pos));
        content.erase(0, pos + delim.length());
    }
    tokens.push_back(content);  // Inserting the last token
    return tokens;
}

std::vector<uint64_t> splitStringUint(const std::string& str, const std::string& delim) {
    std::vector<uint64_t> tokens;
    if (str.empty()) return tokens;
    size_t pos = 0;
    std::string token;
    std::string content = str;  // Copy of str so we can safely erase content
    while ((pos = content.find(delim)) != std::string::npos) {
        token = content.substr(0, pos);
        tokens.push_back(std::stoull(token));  // Convert string to uint64_t and push to vector
        content.erase(0, pos + delim.length());
    }
    tokens.push_back(std::stoull(content));  // Inserting the last token
    return tokens;
}
