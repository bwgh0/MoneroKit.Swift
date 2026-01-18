import MoneroKit
import SwiftUI

struct WalletSetupView: View {
    @Binding var mnemonicSeed: String
    @Binding var walletId: String
    @Binding var daemonAddress: String
    @Binding var restoreHeight: String
    @Binding var mnemonicType: String
    @Binding var passphrase: String
    var connectAction: () -> Void

    private let mnemonicTypes = ["BIP39", "Legacy (25 words)", "Polyseed (16 words)"]

    var body: some View {
        Form {
            Section(header: Text("Wallet Recovery (Test Data)")) {
                Picker("Mnemonic Type", selection: $mnemonicType) {
                    ForEach(mnemonicTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                TextField("Mnemonic Seed", text: $mnemonicSeed)
                TextField("Passphrase (optional)", text: $passphrase)
                TextField("Wallet Name", text: $walletId)
            }
            Section(header: Text("Node Configuration")) {
                TextField("Daemon Address", text: $daemonAddress)
                TextField("Restore Height", text: $restoreHeight)
            }
            Button("Connect or Recover Wallet", action: connectAction)
        }
    }
}
