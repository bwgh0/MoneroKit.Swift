import CMonero
import Foundation

/// Why `Kit.signMessage(_:subaddress:)` did not sign. The Android kit uses
/// the same cases for the same rules.
public enum SignMessageError: Error, Equatable, LocalizedError {
    /// The message has a byte outside printable ASCII (0x20 to 0x7E), for
    /// example a NUL or a non-ASCII letter, or it is longer than 1024 bytes.
    case invalidMessage
    /// No wallet is open in this kit.
    case walletNotOpen
    /// The spend key is on a hardware device (Trezor or Ledger). Hardware
    /// wallets cannot sign messages in v1.
    case hardwareWallet
    /// The wallet has no spend key. wallet2 would sign with an empty key and
    /// return a signature that fails verification, with no error.
    case viewOnlyWallet
    /// The address is not a subaddress of this wallet. It is not a
    /// subaddress of the wallet's network, it belongs to another wallet, or
    /// it holds the wallet's primary keys (the primary address, an
    /// integrated address, or a subaddress encoding of the primary keys).
    case notOwnSubaddress
    /// wallet2 refused with a status error. The value is wallet2's error text.
    case walletError(String)
    /// wallet2 returned a result that does not start with "SigV2".
    case notSigV2
    /// wallet2 verification rejected the new signature for this subaddress.
    case selfCheckFailed

    public var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "The message must be printable ASCII and at most 1024 bytes."
        case .walletNotOpen:
            return "Wallet isn't open."
        case .hardwareWallet:
            return "A hardware wallet can't sign messages."
        case .viewOnlyWallet:
            return "A view-only wallet can't sign messages."
        case .notOwnSubaddress:
            return "The address isn't a subaddress of this wallet."
        case .walletError(let message):
            return message
        case .notSigV2:
            return "The wallet returned an unknown signature format."
        case .selfCheckFailed:
            return "The new signature failed its check."
        }
    }
}

/// wallet2 message signing with a subaddress spend key: SigV2 in spend mode.
/// The SigV2 hash binds the subaddress spend and view public keys. Every
/// refusal except the result checks happens before wallet2 signs.
enum MessageSigner {
    static let maxMessageBytes = 1024

    /// Printable ASCII only (0x20 to 0x7E), at most 1024 bytes. The C bridge
    /// takes a NUL-terminated string, so a NUL would cut the message short.
    static func checkMessage(_ message: String) throws {
        let bytes = message.utf8
        guard bytes.count <= maxMessageBytes, bytes.allSatisfy({ (0x20 ... 0x7E).contains($0) }) else {
            throw SignMessageError.invalidMessage
        }
    }

    /// Call on the queue that owns `walletPointer`.
    static func sign(_ message: String, subaddress: String, walletPointer: UnsafeMutableRawPointer) throws -> String {
        try checkMessage(message)

        guard MONERO_Wallet_getDeviceType(walletPointer) == MoneroCore.DeviceType.software.rawValue else {
            throw SignMessageError.hardwareWallet
        }
        // wallet2::sign has no watch-only check.
        guard !MONERO_Wallet_watchOnly(walletPointer) else {
            throw SignMessageError.viewOnlyWallet
        }

        // wallet2 also signs for the primary address and for an integrated
        // address, with the primary spend key. It finds the key by the
        // address's spend public key only, so a subaddress encoding of the
        // primary key pair gets the primary key too.
        let networkType = MONERO_Wallet_nettype(walletPointer)
        guard let spendKey = subaddressSpendKey(subaddress, networkType: networkType),
              let primarySpendKey = stringFromCString(MONERO_Wallet_publicSpendKey(walletPointer)),
              hex(spendKey) != primarySpendKey.lowercased()
        else {
            throw SignMessageError.notOwnSubaddress
        }

        // wallet2 returns "" when it refuses (an address of another wallet,
        // or background sync) and sets a status error. It never clears an
        // older status error first, and a failed refresh leaves one behind.
        // So the empty result is the failure signal, and the status only
        // gives the text.
        let signature = stringFromCString(MONERO_Wallet_signMessage(walletPointer, message, subaddress)) ?? ""
        guard !signature.isEmpty else {
            let status = MONERO_Wallet_status(walletPointer)
            let error = stringFromCString(MONERO_Wallet_errorString(walletPointer)) ?? ""
            if error.contains("doesn't belong to the wallet") || error.contains("Failed to parse address") {
                throw SignMessageError.notOwnSubaddress
            }
            throw SignMessageError.walletError(status != 0 && !error.isEmpty ? error : "No signature from wallet2")
        }
        guard signature.hasPrefix("SigV2") else {
            throw SignMessageError.notSigV2
        }
        guard MONERO_Wallet_verifySignedMessage(walletPointer, message, subaddress, signature) else {
            throw SignMessageError.selfCheckFailed
        }
        return signature
    }

    /// Subaddress tags (the address's leading varint) by wallet2 network
    /// type: mainnet 42, testnet 63, stagenet 36.
    static func subaddressTag(networkType: Int32) -> UInt8? {
        switch networkType {
        case 0: return 42
        case 1: return 63
        case 2: return 36
        default: return nil
        }
    }

    /// The spend public key of `address` when it is a valid subaddress of
    /// this network, else nil. wallet2 checks the checksum.
    static func subaddressSpendKey(_ address: String, networkType: Int32) -> [UInt8]? {
        guard let tag = subaddressTag(networkType: networkType),
              let bytes = MoneroBase58.decode(address),
              bytes.count == 69, bytes[0] == tag,
              MONERO_Wallet_addressValid(address, networkType)
        else { return nil }
        return Array(bytes[1 ..< 33])
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Monero base58: each 8-byte block is 11 characters (big endian), and a
/// shorter last block uses fewer characters.
enum MoneroBase58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    /// Characters for a block of 0 to 8 bytes.
    private static let encodedBlockSizes = [0, 2, 3, 5, 6, 7, 9, 10, 11]

    static func decode(_ string: String) -> [UInt8]? {
        let chars = Array(string.utf8)
        guard let lastBlockBytes = encodedBlockSizes.firstIndex(of: chars.count % 11) else { return nil }
        var bytes: [UInt8] = []
        var start = 0
        while start < chars.count {
            let end = min(start + 11, chars.count)
            let size = end - start == 11 ? 8 : lastBlockBytes
            guard let block = decodeBlock(chars[start ..< end], size: size) else { return nil }
            bytes += block
            start = end
        }
        return bytes
    }

    private static func decodeBlock(_ chars: ArraySlice<UInt8>, size: Int) -> [UInt8]? {
        var value: UInt64 = 0
        for char in chars {
            guard let digit = alphabet.firstIndex(of: char) else { return nil }
            let (product, overflow) = value.multipliedReportingOverflow(by: 58)
            let (sum, carry) = product.addingReportingOverflow(UInt64(digit))
            guard !overflow, !carry else { return nil }
            value = sum
        }
        if size < 8, value >> (8 * size) != 0 { return nil }
        return (0 ..< size).map { UInt8(truncatingIfNeeded: value >> (8 * (size - 1 - $0))) }
    }
}
