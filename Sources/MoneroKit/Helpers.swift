import BigInt
import CMonero
import Foundation
import HdWalletKit
import HsToolKit

private let saltPrefix = "mnemonic"
private let coinType: UInt32 = 128
private let ed25519CurveOrderHex = "1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED"

func stringFromCString(_ cString: UnsafePointer<Int8>!) -> String? {
    guard let cString else { return nil }
    let swiftString = String(cString: cString)
    MONERO_free(UnsafeMutableRawPointer(mutating: cString))
    return swiftString
}

/// wallet2 renders a syntactically valid address even when its account keys
/// were never loaded (a failed `.keys` read leaves them default-constructed,
/// i.e. all zero bytes). No private key exists for that address — an all-zero
/// public key has no corresponding scalar — so funds sent to it are burned.
/// These are the exact base58 renderings of net-byte + 64 zero bytes +
/// checksum; anything matching them must never be shown, stored, or accepted
/// as a receive address.
public enum NullKeyAddress {
    public static let mainnet = "41d7FXjswpK1111111111111111111111111111111111111111111111111111111111111111111111111111112KhNi4"
    public static let testnet = "9sAejnQ9EBR1111111111111111111111111111111111111111111111111111111111111111111111111111115GTCxb"

    /// A 64-char all-zero hex string — what wallet2 returns for a secret key
    /// that was never loaded.
    public static let zeroSecretKey = String(repeating: "0", count: 64)

    public static func isNullKey(_ address: String) -> Bool {
        address == mainnet || address == testnet
    }
}

/// Monero secret spend key (32-byte little-endian scalar, hex) for a BIP39
/// mnemonic: PBKDF2 seed → BIP44 m/44'/128'/0'/0/0 secp256k1 key → reduced
/// mod the ed25519 group order. This is the wallet-defining derivation for
/// `.bip39` wallets — the golden test in Bip39DerivationTests pins it, and
/// every wallet created since the scheme shipped depends on it not moving.
func spendKeyHexFromBip39(mnemonic: [String], passphrase: String = "") throws -> String {
    guard let seed = Mnemonic.seed(mnemonic: mnemonic, prefix: saltPrefix, passphrase: passphrase) else {
        throw MoneroKitError.invalidSeed
    }

    let hdWallet = HDWallet(seed: seed, coinType: coinType, xPrivKey: HDExtendedKeyVersion.xprv.rawValue)
    let secp256kPrivateKey = try hdWallet.privateKey(account: 0, index: 0, chain: .external).raw
    return Data(reduceECKey(secp256kPrivateKey.bytes)).hs.hex
}

func legacySeedFromBip39(mnemonic: [String], passphrase: String = "") throws -> String {
    let spendKeyHex = try spendKeyHexFromBip39(mnemonic: mnemonic, passphrase: passphrase)

    // `!isEmpty` matters: bytesToWords is a fork addition to wallet2, and a
    // library build that lacks it stubs it with "". Treating that as a valid
    // seed sends an empty mnemonic into wallet2's recovery, which fails and
    // leaves a keyless wallet — fail here instead.
    guard let legacySeed = legacySeedFromKey(key: spendKeyHex), !legacySeed.isEmpty else {
        throw MoneroKitError.invalidSeed
    }

    return legacySeed
}

func legacySeedFromKey(key: String) -> String? {
    let wordsCString = MONERO_Wallet_bytesToWords(key)
    return stringFromCString(wordsCString)
}

func reduceECKey(_ buffer: [UInt8]) -> [UInt8] {
    let curveOrder = BigUInt(ed25519CurveOrderHex, radix: 16)!
    let bigNumber = readBytes(buffer)

    var result = bigNumber % curveOrder

    // Convert result (BigUInt) to little-endian [UInt8] with 32 bytes
    var resultBuffer = [UInt8](repeating: 0, count: 32)
    for i in 0 ..< 32 {
        resultBuffer[i] = UInt8(result & 0xFF)
        result >>= 8
    }

    return resultBuffer
}

func readBytes(_ bytes: [UInt8]) -> BigUInt {
    var result = BigUInt(0)
    for (i, byte) in bytes.enumerated() {
        result += BigUInt(byte) << (8 * i)
    }
    return result
}
