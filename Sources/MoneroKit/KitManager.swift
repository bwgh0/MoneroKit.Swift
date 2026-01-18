import Foundation

class KitManager {
    enum KitState {
        case running, waiting, obselete
    }

    static let shared = KitManager()

    private let queue = DispatchQueue(label: "io.horizontalsystems.monero_kit.kit_manager", qos: .userInitiated)
    private var runningKitId: String?
    private var waitingKitId: String?

    func isRunning(kitId: String) -> Bool {
        queue.sync {
            runningKitId == kitId
        }
    }

    func waitingKitExists() -> Bool {
        queue.sync {
            waitingKitId != nil
        }
    }

    func checkAndGetInitialState(kitId: String) -> KitState {
        queue.sync {
            if let runningKitId, runningKitId != kitId {
                waitingKitId = kitId
                return .waiting
            } else {
                runningKitId = kitId
                return .running
            }
        }
    }

    func checkAndGetState(kitId: String) -> KitState {
        queue.sync {
            if let runningKitId, runningKitId != kitId {
                if let waitingKitId, waitingKitId == kitId {
                    return .waiting
                } else {
                    return .obselete
                }
            } else {
                runningKitId = kitId
                return .running
            }
        }
    }

    func removeRunning(kitId: String) {
        queue.sync {
            if runningKitId == kitId {
                runningKitId = nil
            }
        }
    }
}
