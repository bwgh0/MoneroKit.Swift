import XCTest
@testable import MoneroKit

/// Pins the null-key burn addresses — what wallet2 renders when its account
/// keys were never loaded (default-constructed, all zero bytes). The Thai
/// incident: a failed `.keys` open left a keyless wallet2 object live, the
/// Receive screen served this address, and 0.4055 XMR was burned. Every
/// address surface now filters on `NullKeyAddress.isNullKey`; these tests
/// verify the constants really are the base58 renderings of
/// net-byte + 64 zero bytes, so the filter can't drift.
final class NullKeyAddressTests: XCTestCase {

    // Monero base58: 8-byte blocks encode to 11 chars, the trailing partial
    // block to a fixed smaller width. Decode is enough to pin the payload;
    // the checksum bytes are asserted by total length.
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private func decodeBlock(_ chars: ArraySlice<Character>, byteCount: Int) -> [UInt8]? {
        var num: UInt64 = 0
        for c in chars {
            guard let digit = Self.alphabet.firstIndex(of: c) else { return nil }
            num = num * 58 + UInt64(digit)
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in stride(from: byteCount - 1, through: 0, by: -1) {
            bytes[i] = UInt8(num & 0xFF)
            num >>= 8
        }
        return bytes
    }

    private func moneroBase58Decode(_ s: String) -> [UInt8]? {
        let chars = Array(s)
        let fullBlocks = chars.count / 11
        let remainder = chars.count % 11
        // Partial-block encoded widths for 1...7 payload bytes
        let partialSizes: [Int: Int] = [2: 1, 3: 2, 5: 3, 6: 4, 7: 5, 9: 6, 10: 7]
        var out: [UInt8] = []
        for b in 0 ..< fullBlocks {
            guard let bytes = decodeBlock(chars[(b * 11) ..< ((b + 1) * 11)], byteCount: 8) else { return nil }
            out += bytes
        }
        if remainder > 0 {
            guard let byteCount = partialSizes[remainder],
                  let bytes = decodeBlock(chars[(fullBlocks * 11)...], byteCount: byteCount) else { return nil }
            out += bytes
        }
        return out
    }

    private func assertNullKeyPayload(_ address: String, netByte: UInt8) {
        guard let payload = moneroBase58Decode(address) else {
            return XCTFail("address failed base58 decode")
        }
        // net byte + 32-byte spend key + 32-byte view key + 4-byte checksum
        XCTAssertEqual(payload.count, 69)
        XCTAssertEqual(payload[0], netByte)
        XCTAssertTrue(payload[1 ..< 65].allSatisfy { $0 == 0 },
                      "both public keys must decode to all-zero bytes")
    }

    func testMainnetConstantIsZeroKeyAddress() {
        assertNullKeyPayload(NullKeyAddress.mainnet, netByte: 0x12)
    }

    func testTestnetConstantIsZeroKeyAddress() {
        assertNullKeyPayload(NullKeyAddress.testnet, netByte: 0x35)
    }

    func testIsNullKeyMatchesOnlyTheConstants() {
        XCTAssertTrue(NullKeyAddress.isNullKey(NullKeyAddress.mainnet))
        XCTAssertTrue(NullKeyAddress.isNullKey(NullKeyAddress.testnet))
        XCTAssertFalse(NullKeyAddress.isNullKey(""))
        // A real mainnet address must never be filtered
        XCTAssertFalse(NullKeyAddress.isNullKey(
            "467GWhAFLTiGpGxNifmiGE1VnwGM6RUAqYYPeghZnkhLWPPVArz7AtE3x4vsaexoG6aP4aKVosTUMDHCRnHgF3FfTjdHKoH"
        ))
    }

    func testZeroSecretKeyConstant() {
        XCTAssertEqual(NullKeyAddress.zeroSecretKey.count, 64)
        XCTAssertTrue(NullKeyAddress.zeroSecretKey.allSatisfy { $0 == "0" })
    }
}
