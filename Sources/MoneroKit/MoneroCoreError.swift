import Foundation

public enum MoneroCoreError: Error, LocalizedError {
    case walletNotInitialized
    case walletStatusError(String?)
    case insufficientFunds(String)
    case transactionEstimationFailed(String)
    case transactionSendFailed(String)
    case transactionCommitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .walletNotInitialized:
            return "Wallet isn't initialized."
        case .walletStatusError(let msg):
            return msg ?? "Wallet returned an error."
        case .insufficientFunds(let balance):
            return "Insufficient funds — wallet has only \(balance) XMR available."
        case .transactionEstimationFailed(let msg):
            return "Couldn't estimate fee: \(msg)"
        case .transactionSendFailed(let msg):
            return "Couldn't build transaction: \(msg)"
        case .transactionCommitFailed(let msg):
            return "Couldn't broadcast transaction: \(msg)"
        }
    }

    static func match(_ errorStr: String) -> MoneroCoreError? {
        let pattern = #"^not enough money to transfer, overall balance only (\d+\.\d+), sent amount \d+\.\d+$"#

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let nsString = errorStr as NSString
            let results = regex.matches(in: errorStr, options: [], range: NSRange(location: 0, length: nsString.length))

            if let match = results.first {
                // Extract the captured group (balance value)
                let balanceRange = match.range(at: 1)
                if balanceRange.location != NSNotFound {
                    let balance = nsString.substring(with: balanceRange)
                    return .insufficientFunds(balance)
                }
            }
        } catch {}

        return nil
    }
}
