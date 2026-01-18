//
//  DemoApp.swift
//  Demo
//
//  Created by Esenbek Kydyr uulu on 31/5/25.
//

import MoneroKit
import SwiftUI

@main
struct DemoApp: App {
    @StateObject private var walletState = App_WalletState()
    @State private var moneroKit: Kit?

    var body: some Scene {
        WindowGroup {
            ContentView(moneroKit: $moneroKit, walletState: walletState)
        }
    }
}
