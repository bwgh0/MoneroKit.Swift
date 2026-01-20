//
//  LightWalletCore.swift
//  MoneroKit
//
//  Light wallet transaction creation using MyMonero's proven implementation.
//  This bypasses wallet2's incomplete light wallet mode and uses the MyMonero
//  SendFundsFormSubmissionController for reliable transaction creation.
//

import Foundation
#if canImport(CMyMoneroCore)
import CMyMoneroCore
#endif

// MARK: - Light Wallet Types

public enum LightWalletNetType {
    case mainnet
    case testnet
    case stagenet

    #if canImport(CMyMoneroCore)
    var mmNetType: MMNetType {
        switch self {
        case .mainnet: return .mainnet
        case .testnet: return .testnet
        case .stagenet: return .stagenet
        }
    }
    #endif
}

public enum LightWalletPriority: UInt32 {
    case low = 1
    case medLow = 2
    case medHigh = 3
    case high = 4
}

// MARK: - Light Wallet Transaction Result

public struct LightWalletTransactionResult {
    public let txHash: String
    public let txKey: String
    public let txPubKey: String
    public let txHex: String
    public let usedFee: UInt64
    public let totalSent: UInt64
    public let mixin: UInt
    public let targetAddress: String
    public let paymentId: String?
}

// MARK: - Light Wallet Error

public enum LightWalletError: Error {
    case notImplemented
    case invalidAddress
    case invalidKeys
    case insufficientFunds(spendable: UInt64, required: UInt64)
    case transactionCreationFailed(String)
    case networkError(String)
    case serverError(String)
    case cancelled
}

// MARK: - Light Wallet API Client

public class LightWalletAPIClient {
    public let serverURL: URL
    private let session: URLSession

    public init(serverURL: URL) {
        self.serverURL = serverURL
        self.session = URLSession.shared
    }

    // MARK: - API Endpoints

    public func getUnspentOuts(
        address: String,
        viewKey: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let params: [String: Any] = [
            "address": address,
            "view_key": viewKey,
            "amount": "0",
            "mixin": 15,
            "use_dust": true,
            "dust_threshold": "2000000000"
        ]

        post(endpoint: "get_unspent_outs", params: params, completion: completion)
    }

    public func getRandomOuts(
        amounts: [String],
        count: Int,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let params: [String: Any] = [
            "amounts": amounts,
            "count": count
        ]

        post(endpoint: "get_random_outs", params: params, completion: completion)
    }

    public func submitRawTx(
        address: String,
        viewKey: String,
        txHex: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let params: [String: Any] = [
            "address": address,
            "view_key": viewKey,
            "tx": txHex
        ]

        post(endpoint: "submit_raw_tx", params: params) { result in
            switch result {
            case .success(let data):
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "OK" {
                    completion(.success(()))
                } else {
                    let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    completion(.failure(LightWalletError.serverError(error ?? "Transaction rejected")))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func post(
        endpoint: String,
        params: [String: Any],
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard let url = URL(string: endpoint, relativeTo: serverURL) else {
            completion(.failure(LightWalletError.networkError("Invalid URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: params)

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(LightWalletError.networkError(error.localizedDescription)))
                return
            }

            guard let data = data else {
                completion(.failure(LightWalletError.networkError("No data received")))
                return
            }

            completion(.success(data))
        }.resume()
    }
}

// MARK: - Light Wallet Transaction Builder

public class LightWalletTransactionBuilder {

    private let apiClient: LightWalletAPIClient
    private let address: String
    private let privateViewKey: String
    private let privateSpendKey: String
    private let publicSpendKey: String
    private let netType: LightWalletNetType

    public init(
        serverURL: URL,
        address: String,
        privateViewKey: String,
        privateSpendKey: String,
        publicSpendKey: String,
        netType: LightWalletNetType = .mainnet
    ) {
        self.apiClient = LightWalletAPIClient(serverURL: serverURL)
        self.address = address
        self.privateViewKey = privateViewKey
        self.privateSpendKey = privateSpendKey
        self.publicSpendKey = publicSpendKey
        self.netType = netType
    }

    // MARK: - Transaction Creation

    #if canImport(CMyMoneroCore)

    /// Send funds using MyMonero's JSON serial bridge API
    /// This is a multi-step process:
    /// 1. Get unspent outputs from the server
    /// 2. Prepare parameters for getting decoy outputs
    /// 3. Get random outputs (decoys) from the server
    /// 4. Tie unspent outputs to mix outputs
    /// 5. Try to create the transaction
    /// 6. Submit the raw transaction to the server
    public func send(
        toAddress: String,
        amount: UInt64,
        paymentId: String? = nil,
        priority: LightWalletPriority = .low,
        isSweeping: Bool = false,
        onStatusUpdate: ((String) -> Void)? = nil,
        completion: @escaping (Result<LightWalletTransactionResult, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            self.performSend(
                toAddress: toAddress,
                amount: amount,
                paymentId: paymentId,
                priority: priority,
                isSweeping: isSweeping,
                onStatusUpdate: onStatusUpdate,
                completion: { result in
                    DispatchQueue.main.async {
                        completion(result)
                    }
                }
            )
        }
    }

    private func performSend(
        toAddress: String,
        amount: UInt64,
        paymentId: String? = nil,
        priority: LightWalletPriority,
        isSweeping: Bool,
        onStatusUpdate: ((String) -> Void)?,
        completion: @escaping (Result<LightWalletTransactionResult, Error>) -> Void
    ) {
        // Step 1: Fetch unspent outputs
        onStatusUpdate?("Fetching unspent outputs...")

        let semaphore = DispatchSemaphore(value: 0)
        var unspentOutsJSON: String?
        var fetchError: Error?

        apiClient.getUnspentOuts(address: address, viewKey: privateViewKey) { result in
            switch result {
            case .success(let data):
                unspentOutsJSON = String(data: data, encoding: .utf8)
            case .failure(let error):
                fetchError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard let unspentOuts = unspentOutsJSON else {
            completion(.failure(fetchError ?? LightWalletError.networkError("Failed to fetch unspent outputs")))
            return
        }

        // Step 2: Prepare params for getting decoys
        onStatusUpdate?("Preparing transaction...")

        let step1Args = buildStep1Args(
            toAddress: toAddress,
            amount: amount,
            paymentId: paymentId,
            priority: priority,
            isSweeping: isSweeping,
            unspentOutsJSON: unspentOuts
        )

        guard let step1Result = MyMoneroCore_ObjCpp.prepareParams(forGetDecoys: step1Args) else {
            completion(.failure(LightWalletError.transactionCreationFailed("Failed to prepare decoy params")))
            return
        }

        // Check for error in step1 result
        if let error = parseError(from: step1Result) {
            completion(.failure(LightWalletError.transactionCreationFailed(error)))
            return
        }

        // Extract amounts to get decoys for from using_outs
        guard let step1Data = step1Result.data(using: .utf8),
              let step1JSON = try? JSONSerialization.jsonObject(with: step1Data) as? [String: Any],
              let usingOuts = step1JSON["using_outs"] as? [[String: Any]] else {
            completion(.failure(LightWalletError.transactionCreationFailed("Invalid step1 response - missing using_outs")))
            return
        }

        // For RingCT transactions (all modern Monero), decoys are always requested for amount "0"
        // because RingCT hides the actual amounts
        let amounts = ["0"]
        print("[LightWalletCore] Requesting decoys for amounts: \(amounts) (RingCT always uses 0)")

        // Step 3: Fetch random outputs (decoys)
        onStatusUpdate?("Fetching decoy outputs...")

        var randomOutsJSON: String?
        apiClient.getRandomOuts(amounts: amounts, count: 16) { result in
            switch result {
            case .success(let data):
                randomOutsJSON = String(data: data, encoding: .utf8)
            case .failure(let error):
                fetchError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard let randomOuts = randomOutsJSON else {
            completion(.failure(fetchError ?? LightWalletError.networkError("Failed to fetch random outputs")))
            return
        }

        // Step 4: Tie unspent outs to mix outs
        onStatusUpdate?("Preparing ring signatures...")

        let preStep2Args = buildPreStep2Args(
            step1Result: step1Result,
            mixOutsJSON: randomOuts
        )

        // Check for build errors before calling C++ function
        if let error = parseError(from: preStep2Args) {
            completion(.failure(LightWalletError.transactionCreationFailed(error)))
            return
        }

        guard let preStep2Result = MyMoneroCore_ObjCpp.tieUnspentOuts(toMixOuts: preStep2Args) else {
            completion(.failure(LightWalletError.transactionCreationFailed("Failed to tie outputs")))
            return
        }

        if let error = parseError(from: preStep2Result) {
            completion(.failure(LightWalletError.transactionCreationFailed(error)))
            return
        }

        // Step 5: Create the transaction
        onStatusUpdate?("Constructing transaction...")

        let step2Args = buildStep2Args(
            step1Result: step1Result,
            preStep2Result: preStep2Result,
            toAddress: toAddress,
            amount: amount,
            paymentId: paymentId,
            priority: priority,
            isSweeping: isSweeping
        )

        // Check for build errors before calling C++ function
        if let error = parseError(from: step2Args) {
            completion(.failure(LightWalletError.transactionCreationFailed(error)))
            return
        }

        NSLog("[LightWalletCore] step2Args length: %d", step2Args.count)
        NSLog("[LightWalletCore] Calling tryCreateTransaction...")
        let startTime = Date()

        guard let step2Result = MyMoneroCore_ObjCpp.tryCreateTransaction(step2Args) else {
            NSLog("[LightWalletCore] tryCreateTransaction returned nil after %.2fs", Date().timeIntervalSince(startTime))
            completion(.failure(LightWalletError.transactionCreationFailed("Failed to create transaction")))
            return
        }

        NSLog("[LightWalletCore] tryCreateTransaction completed in %.2fs", Date().timeIntervalSince(startTime))
        NSLog("[LightWalletCore] step2Result length: %d, preview: %@", step2Result.count, String(step2Result.prefix(200)))

        if let error = parseError(from: step2Result) {
            NSLog("[LightWalletCore] step2 error detected: %@", error)
            completion(.failure(LightWalletError.transactionCreationFailed(error)))
            return
        }

        // Parse transaction result
        guard let resultData = step2Result.data(using: .utf8),
              let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            completion(.failure(LightWalletError.transactionCreationFailed("Invalid transaction result")))
            return
        }

        guard let txHash = resultJSON["tx_hash"] as? String,
              let txHex = resultJSON["serialized_signed_tx"] as? String else {
            completion(.failure(LightWalletError.transactionCreationFailed("Missing transaction data")))
            return
        }

        // Step 6: Submit the transaction
        onStatusUpdate?("Submitting transaction...")

        var submitError: Error?
        var submitSuccess = false

        apiClient.submitRawTx(address: address, viewKey: privateViewKey, txHex: txHex) { result in
            switch result {
            case .success:
                submitSuccess = true
            case .failure(let error):
                submitError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard submitSuccess else {
            completion(.failure(submitError ?? LightWalletError.networkError("Failed to submit transaction")))
            return
        }

        // Build result
        let txResult = LightWalletTransactionResult(
            txHash: txHash,
            txKey: resultJSON["tx_key"] as? String ?? "",
            txPubKey: resultJSON["tx_pub_key"] as? String ?? "",
            txHex: txHex,
            usedFee: UInt64(resultJSON["used_fee"] as? String ?? "0") ?? 0,
            totalSent: UInt64(resultJSON["total_sent"] as? String ?? "0") ?? 0,
            mixin: UInt(resultJSON["mixin"] as? Int ?? 15),
            targetAddress: toAddress,
            paymentId: paymentId
        )

        onStatusUpdate?("Transaction sent!")
        completion(.success(txResult))
    }

    // MARK: - JSON Argument Builders

    private func buildStep1Args(
        toAddress: String,
        amount: UInt64,
        paymentId: String?,
        priority: LightWalletPriority,
        isSweeping: Bool,
        unspentOutsJSON: String
    ) -> String {
        // Parse server response JSON
        guard let unspentData = unspentOutsJSON.data(using: .utf8),
              let serverResponse = try? JSONSerialization.jsonObject(with: unspentData) as? [String: Any],
              let outputs = serverResponse["outputs"] as? [[String: Any]] else {
            return "{}"
        }

        // Extract fee info from server response
        let feePerB = serverResponse["per_byte_fee"] as? Int ?? 20000
        let feeMask = serverResponse["fee_mask"] as? Int ?? 10000

        // MyMonero serial bridge expects:
        // - unspent_outs: array of outputs directly (not nested under "outputs")
        // - fee_per_b and fee_mask as strings at top level
        // IMPORTANT: Do NOT include payment_id_string if nil - the C++ code treats
        // even an empty string as "payment ID present" which fails for subaddresses
        var args: [String: Any] = [
            "is_sweeping": isSweeping,
            "sending_amount": isSweeping ? "0" : String(amount),
            "fee_per_b": String(feePerB),
            "fee_mask": String(feeMask),
            "priority": String(priority.rawValue),
            "unspent_outs": outputs,  // Array of outputs directly
            "nettype_string": netTypeString()
        ]

        // Only include payment_id_string if explicitly provided (not for subaddresses)
        if let pid = paymentId, !pid.isEmpty {
            args["payment_id_string"] = pid
        }

        if let data = try? JSONSerialization.data(withJSONObject: args),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    private func buildPreStep2Args(
        step1Result: String,
        mixOutsJSON: String
    ) -> String {
        // Combine step1 result with mix outs
        guard let step1Data = step1Result.data(using: .utf8),
              var step1Args = try? JSONSerialization.jsonObject(with: step1Data) as? [String: Any] else {
            print("[LightWalletCore] buildPreStep2Args: Failed to parse step1Result")
            return "{\"err_msg\": \"Failed to parse step1Result\"}"
        }

        // Verify step1Args contains required fields
        guard step1Args["using_outs"] != nil else {
            print("[LightWalletCore] buildPreStep2Args: step1Result missing using_outs. Keys: \(step1Args.keys)")
            return "{\"err_msg\": \"step1Result missing using_outs\"}"
        }

        // Parse mix_outs JSON - server returns "amount_outs" but MyMonero expects "mix_outs"
        guard let mixOutsData = mixOutsJSON.data(using: .utf8) else {
            print("[LightWalletCore] buildPreStep2Args: Failed to convert mixOutsJSON to data")
            return "{\"err_msg\": \"Failed to convert mixOutsJSON to data\"}"
        }

        guard let serverResponse = try? JSONSerialization.jsonObject(with: mixOutsData) as? [String: Any] else {
            print("[LightWalletCore] buildPreStep2Args: Failed to parse mixOutsJSON. First 200 chars: \(String(mixOutsJSON.prefix(200)))")
            return "{\"err_msg\": \"Failed to parse mixOutsJSON as dictionary\"}"
        }

        print("[LightWalletCore] buildPreStep2Args: mixOuts keys: \(serverResponse.keys)")

        guard let amountOuts = serverResponse["amount_outs"] as? [[String: Any]] else {
            print("[LightWalletCore] buildPreStep2Args: amount_outs not found or wrong type. Keys: \(serverResponse.keys)")
            return "{\"err_msg\": \"amount_outs not found in mixOutsJSON\"}"
        }

        // Pass the amount_outs array as mix_outs
        step1Args["mix_outs"] = amountOuts

        if let data = try? JSONSerialization.data(withJSONObject: step1Args),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"err_msg\": \"Failed to serialize preStep2Args\"}"
    }

    private func buildStep2Args(
        step1Result: String,
        preStep2Result: String,
        toAddress: String,
        amount: UInt64,
        paymentId: String?,
        priority: LightWalletPriority,
        isSweeping: Bool
    ) -> String {
        // Parse step1Result to get using_outs
        guard let step1Data = step1Result.data(using: .utf8),
              let step1Args = try? JSONSerialization.jsonObject(with: step1Data) as? [String: Any],
              let usingOuts = step1Args["using_outs"] else {
            print("[LightWalletCore] buildStep2Args: Failed to extract using_outs from step1Result")
            return "{\"err_msg\": \"Failed to extract using_outs from step1Result\"}"
        }

        // Parse preStep2Result
        guard let preStep2Data = preStep2Result.data(using: .utf8),
              var args = try? JSONSerialization.jsonObject(with: preStep2Data) as? [String: Any] else {
            print("[LightWalletCore] buildStep2Args: Failed to parse preStep2Result")
            return "{\"err_msg\": \"Failed to parse preStep2Result\"}"
        }

        // Include using_outs from step1
        args["using_outs"] = usingOuts

        // Include other step1 fields needed by step2
        // Note: step2 expects certain field names that differ from step1's output
        if let mixin = step1Args["mixin"] {
            args["mixin"] = mixin
        }
        if let usingFee = step1Args["using_fee"] {
            // step2 expects "fee_amount" instead of "using_fee"
            args["fee_amount"] = usingFee
        }
        if let changeAmount = step1Args["change_amount"] {
            args["change_amount"] = changeAmount
        }
        if let finalTotalWoFee = step1Args["final_total_wo_fee"] {
            args["final_total_wo_fee"] = finalTotalWoFee
        }

        // step2 also needs fee_per_b and fee_mask (these might be in step1Args if we preserved them)
        // If not, use defaults from the original unspent_outs response
        if args["fee_per_b"] == nil {
            args["fee_per_b"] = "20000"  // Default, should be overridden from actual data
        }
        if args["fee_mask"] == nil {
            args["fee_mask"] = "10000"  // Default, should be overridden from actual data
        }

        // Add wallet credentials and transaction parameters
        args["to_address_string"] = toAddress
        args["from_address_string"] = address
        args["sec_viewKey_string"] = privateViewKey
        args["sec_spendKey_string"] = privateSpendKey
        args["pub_spendKey_string"] = publicSpendKey
        args["is_sweeping"] = isSweeping
        args["sending_amount"] = isSweeping ? "0" : String(amount)
        // Only include payment_id_string if explicitly provided (not for subaddresses)
        if let pid = paymentId, !pid.isEmpty {
            args["payment_id_string"] = pid
        }
        args["priority"] = String(priority.rawValue)
        args["unlock_time"] = "0"
        args["nettype_string"] = netTypeString()

        if let data = try? JSONSerialization.data(withJSONObject: args),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"err_msg\": \"Failed to serialize step2Args\"}"
    }

    private func netTypeString() -> String {
        switch netType {
        case .mainnet: return "MAINNET"
        case .testnet: return "TESTNET"
        case .stagenet: return "STAGENET"
        }
    }

    private func parseError(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errMsg = json["err_msg"] as? String,
              !errMsg.isEmpty else {
            return nil
        }
        return errMsg
    }

    #else

    /// Fallback when CMyMoneroCore is not available
    public func send(
        toAddress: String,
        amount: UInt64,
        paymentId: String? = nil,
        priority: LightWalletPriority = .low,
        isSweeping: Bool = false,
        onStatusUpdate: ((String) -> Void)? = nil,
        completion: @escaping (Result<LightWalletTransactionResult, Error>) -> Void
    ) {
        completion(.failure(LightWalletError.notImplemented))
    }

    #endif

    // MARK: - Utility Functions

    #if canImport(CMyMoneroCore)

    /// Generate a key image for an output
    public static func generateKeyImage(
        txPubKey: String,
        privateViewKey: String,
        publicSpendKey: String,
        privateSpendKey: String,
        outputIndex: UInt64
    ) -> String? {
        return MyMoneroCore_ObjCpp.generateKeyImage(
            withTxPubKey: txPubKey,
            privateViewKey: privateViewKey,
            publicSpendKey: publicSpendKey,
            privateSpendKey: privateSpendKey,
            outputIndex: outputIndex
        )
    }

    /// Estimate transaction fee
    public static func estimateFee(
        feePerByte: UInt64,
        priority: LightWalletPriority,
        forkVersion: UInt8 = 16
    ) -> UInt64 {
        return MyMoneroCore_ObjCpp.estimatedTxNetworkFee(
            withFeePerB: feePerByte,
            priority: priority.rawValue,
            forkVersion: forkVersion
        )
    }

    /// Decode an address
    public static func decodeAddress(
        _ address: String,
        netType: LightWalletNetType = .mainnet
    ) -> [String: Any]? {
        guard let result = MyMoneroCore_ObjCpp.decodeAddress(address, nettype: netType.mmNetType) else {
            return nil
        }
        return result as? [String: Any]
    }

    /// Check if address is a subaddress
    public static func isSubAddress(
        _ address: String,
        netType: LightWalletNetType = .mainnet
    ) -> Bool {
        return MyMoneroCore_ObjCpp.isSubAddress(address, nettype: netType.mmNetType)
    }

    /// Check if address is an integrated address
    public static func isIntegratedAddress(
        _ address: String,
        netType: LightWalletNetType = .mainnet
    ) -> Bool {
        return MyMoneroCore_ObjCpp.isIntegratedAddress(address, nettype: netType.mmNetType)
    }

    /// Derive wallet keys from a mnemonic seed phrase
    /// Returns a dictionary with: seed, mnemonicLanguage, address, privateViewKey, privateSpendKey, publicViewKey, publicSpendKey
    public static func seedAndKeysFromMnemonic(
        _ mnemonic: String,
        netType: LightWalletNetType = .mainnet
    ) -> [String: Any]? {
        guard let result = MyMoneroCore_ObjCpp.seedAndKeys(fromMnemonic: mnemonic, nettype: netType.mmNetType) else {
            return nil
        }
        return result as? [String: Any]
    }

    #endif
}

// MARK: - MoneroCore Extension for Light Wallet Support

#if canImport(CMonero)
import CMonero

extension MoneroCore {

    /// Create a light wallet transaction builder for this wallet
    /// This method extracts wallet keys and creates a builder for light wallet transactions
    func createLightWalletBuilder() -> LightWalletTransactionBuilder? {
        // Get the wallet pointer using internal access
        guard let walletPtr = getWalletPointer() else { return nil }
        guard let serverURL = URL(string: node.url.absoluteString) else { return nil }

        let addressPtr = MONERO_Wallet_address(walletPtr, 0, 0)
        let viewKeyPtr = MONERO_Wallet_secretViewKey(walletPtr)
        let spendKeyPtr = MONERO_Wallet_secretSpendKey(walletPtr)
        let pubSpendKeyPtr = MONERO_Wallet_publicSpendKey(walletPtr)

        guard let address = stringFromCString(addressPtr),
              let viewKey = stringFromCString(viewKeyPtr),
              let spendKey = stringFromCString(spendKeyPtr),
              let pubSpendKey = stringFromCString(pubSpendKeyPtr) else {
            return nil
        }

        return LightWalletTransactionBuilder(
            serverURL: serverURL,
            address: address,
            privateViewKey: viewKey,
            privateSpendKey: spendKey,
            publicSpendKey: pubSpendKey,
            netType: .mainnet
        )
    }

    /// Send using the light wallet implementation (bypasses wallet2's broken LWS mode)
    func sendViaLightWallet(
        address: String,
        amount: SendAmount,
        priority: SendPriority = .default,
        onStatusUpdate: ((String) -> Void)? = nil,
        completion: @escaping (Result<LightWalletTransactionResult, Error>) -> Void
    ) {
        guard node.isLightWallet else {
            completion(.failure(LightWalletError.transactionCreationFailed("Not a light wallet node")))
            return
        }

        guard let builder = createLightWalletBuilder() else {
            completion(.failure(LightWalletError.transactionCreationFailed("Failed to create transaction builder - wallet pointer not accessible")))
            return
        }

        let lwPriority: LightWalletPriority
        switch priority {
        case .default, .low: lwPriority = .low
        case .medium: lwPriority = .medLow
        case .high, .last: lwPriority = .high
        }

        let isSweeping: Bool
        switch amount {
        case .all: isSweeping = true
        case .value: isSweeping = false
        }

        builder.send(
            toAddress: address,
            amount: amount.value,
            priority: lwPriority,
            isSweeping: isSweeping,
            onStatusUpdate: onStatusUpdate,
            completion: completion
        )
    }
}
#endif
