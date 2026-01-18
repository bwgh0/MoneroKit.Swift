import Foundation
import HsToolKit
import ObjectMapper

class DaemonRpcProvider {
    private let baseUrl: String
    private let networkManager: NetworkManager

    init(baseUrl: String, networkManager: NetworkManager) {
        self.baseUrl = baseUrl
        self.networkManager = networkManager
    }
}

extension DaemonRpcProvider {
    func getHeight(jws _: String) async throws -> Int {
        let response: DaemonHeightResponse = try await networkManager.fetch(url: "\(baseUrl)/get_height", method: .get)

        return response.height
    }
}

extension DaemonRpcProvider {
    struct DaemonHeightResponse: ImmutableMappable {
        let hash: String
        let height: Int
        let status: String
        let untrusted: Bool

        init(map: Map) throws {
            hash = try map.value("hash")
            height = try map.value("height")
            status = try map.value("status")
            untrusted = try map.value("untrusted")
        }
    }
}
