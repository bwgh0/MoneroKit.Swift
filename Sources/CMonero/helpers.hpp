// This file is derived from monero_c (https://github.com/mrcyjanek/monero_c),
// licensed under the GNU Lesser General Public License v3.0 (LGPL-3.0).
// It remains under LGPL-3.0 and is NOT covered by this repository's MIT LICENSE.
// MoneroOne modifications (iOS Trezor support, light-wallet fixes) are published
// as a fork at https://github.com/bwgh0/monero_c. See COPYING.LESSER for the
// full license text and Sources/CMonero/NOTICE for details.

#include <vector>
#include <string>
#include <set>
#include <sstream>
#include <cstdlib>
#include <iostream>

// Debug macros
#define DEBUG_START()                                                             \
    try {

#define DEBUG_END()                                                               \
    } catch (const std::exception &e) {                                           \
        std::cerr << "Exception caught in function: " << __FUNCTION__             \
                  << " at " << __FILE__ << ":" << __LINE__ << std::endl           \
                  << "Message: " << e.what() << std::endl;                        \
        std::abort();                                                                    \
    } catch (...) {                                                               \
        std::cerr << "Unknown exception caught in function: " << __FUNCTION__     \
                  << " at " << __FILE__ << ":" << __LINE__ << std::endl;          \
        std::abort();                                                                    \
    }


const char* vectorToString(const std::vector<std::string>& vec, const std::string separator);
const char* vectorToString(const std::vector<uint32_t>& vec, const std::string separator);
const char* vectorToString(const std::vector<uint64_t>& vec, const std::string separator);
const char* vectorToString(const std::vector<std::set<uint32_t>>& vec, const std::string separator);
const char* vectorToString(const std::set<uint32_t>& intSet, const std::string separator);
std::set<std::string> splitString(const std::string& str, const std::string& delim);
std::vector<uint64_t> splitStringUint(const std::string& str, const std::string& delim);
std::vector<std::string> splitStringVector(const std::string& str, const std::string& delim);
