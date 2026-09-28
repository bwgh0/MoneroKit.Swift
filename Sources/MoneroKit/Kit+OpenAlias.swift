import CMonero
import Foundation

public extension Kit {
    /// DNSSEC-validating TXT lookup. All DNS traffic goes to the DNS-over-TCP
    /// forwarder on the IPv4 loopback at `forwarderPort`. Blocks for up to
    /// `timeoutMs`, so call it off the main thread. Returns the kit JSON
    /// (OpenAlias send spec, section 3.4).
    static func lookupOpenAliasTXT(name: String, forwarderPort: UInt16, timeoutMs: Int32) -> String {
        let raw = name.withCString { MONERO_OpenAlias_lookupTXT($0, Int32(forwarderPort), timeoutMs) }
        return stringFromCString(raw) ?? #"{"status":"error","error":"no result"}"#
    }

    /// The wallet2 OpenAlias resolver, with its DNSSEC flag. The Send flow
    /// leaves it unused (OpenAlias send spec, section 3.1). Blocks with no
    /// time limit, and its first call probes updates.moneropulse.org.
    static func resolveOpenAliasWithWallet2(_ name: String) -> (address: String, dnssecValid: Bool)? {
        guard let manager = MONERO_WalletManagerFactory_getWalletManager() else { return nil }
        var valid = false
        let raw = name.withCString { MONERO_WalletManager_resolveOpenAlias(manager, $0, &valid) }
        guard let address = stringFromCString(raw), !address.isEmpty else { return nil }
        return (address, valid)
    }
}
