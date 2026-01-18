import Foundation

public enum MoneroCoreError: Error {
    case walletNotInitialized
    case walletStatusError(String?)
    case insufficientFunds(String)
    case transactionEstimationFailed(String)
    case transactionSendFailed(String)
    case transactionCommitFailed(String)

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
