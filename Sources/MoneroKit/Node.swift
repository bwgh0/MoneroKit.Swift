import Foundation

public struct Node {
    public let url: URL
    public let isTrusted: Bool
    public let login: String?
    public let password: String?

    public init(url: URL, isTrusted: Bool, login: String? = nil, password: String? = nil) {
        self.url = url
        self.isTrusted = isTrusted
        self.login = login
        self.password = password
    }

    public var description: String {
        let modeStr = isTrusted ? "trusted" : "untrusted"
        return "\(url.absoluteString) (\(modeStr)) \(login == nil ? "no credentials" : "has credentials")"
    }
}
