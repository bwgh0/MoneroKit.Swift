import MoneroKit
import SwiftUI
import HsToolKit

struct ContentView: View {
    @Binding var moneroKit: Kit?
    @ObservedObject var walletState: App_WalletState

    @State private var mnemonicSeed: String = ""
    @State private var passphrase: String = ""
    @State private var walletId: String = "wallet1"
    @State private var daemonAddress: String = "http://xmr-node.cakewallet.com:18081"
    @State private var restoreHeight: String = "\(RestoreHeight.getHeight(date: Date()))"
    @State private var mnemonicType: String = "BIP39"

    var body: some View {
        NavigationView {
            VStack {
                if !walletState.isConnected {
                    WalletSetupView(
                        mnemonicSeed: $mnemonicSeed,
                        walletId: $walletId,
                        daemonAddress: $daemonAddress,
                        restoreHeight: $restoreHeight,
                        mnemonicType: $mnemonicType,
                        passphrase: $passphrase,
                        connectAction: connectToWallet
                    )
                } else {
                    WalletDashboardView(moneroKit: $moneroKit, walletState: walletState)
                }
            }
            .padding()
            .navigationTitle("Monero Wallet")
        }
    }

    private func connectToWallet() {
        guard let url = URL(string: daemonAddress) else {
            return
        }
        let node = Node(url: url, isTrusted: true)
        let seed = mnemonicSeed.components(separatedBy: " ")

        let wallet: MoneroWallet
        switch mnemonicType {
        case "BIP39":
            wallet = .bip39(seed: seed, passphrase: passphrase)
        case "Legacy (25 words)":
            wallet = .legacy(seed: seed, passphrase: passphrase)
        case "Polyseed (16 words)":
            wallet = .polyseed(seed: seed, passphrase: passphrase)
        default:
            return
        }

        guard let kit = try? Kit(
            wallet: wallet,
            account: 0,
            restoreHeight: UInt64(restoreHeight) ?? 0,
            walletId: walletId,
            node: node,
            networkType: .mainnet,
            reachabilityManager: ReachabilityManager(),
            logger: nil,
            moneroCoreLogLevel: 4
        ) else {
            return
        }

        kit.delegate = walletState
        kit.start()

        moneroKit = kit
        walletState.isConnected = true
    }
}
