import Foundation

public struct Node {
    public let url: URL
    public let isTrusted: Bool
    public let isLightWallet: Bool
    public let login: String?
    public let password: String?

    public init(url: URL, isTrusted: Bool, isLightWallet: Bool = false, login: String? = nil, password: String? = nil) {
        self.url = url
        self.isTrusted = isTrusted
        self.isLightWallet = isLightWallet
        self.login = login
        self.password = password
    }

    public var description: String {
        let modeStr = isLightWallet ? "light" : (isTrusted ? "trusted" : "untrusted")
        return "\(url.absoluteString) (\(modeStr)) \(login == nil ? "no credentials" : "has credentials")"
    }
}
