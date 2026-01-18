import MoneroKit
import SwiftUI

struct SubaddressesView: View {
    @Binding var moneroKit: Kit?

    var body: some View {
        List {
            Section(header: Text("My Addresses")) {
                if let addresses = moneroKit?.usedAddresses, !addresses.isEmpty {
                    ForEach(addresses, id: \.address) { subaddress in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Index: \(subaddress.index)")
                                    .font(.caption)
                                Text(subaddress.address)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = subaddress.address
                            }) {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                    }
                } else {
                    Text("No addresses found.")
                }
            }
        }
        .navigationTitle("My Addresses")
    }
}
