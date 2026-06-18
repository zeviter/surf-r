//
//  SurfrApp.swift
//  Surfr
//
//  Created by zeviter on 18/06/2026.
//

import SwiftUI

@main
struct SurfrApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Open Location…") {
                    NotificationCenter.default.post(name: .focusOmnibox, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                #if DEBUG
                Button("Run History Self-Test") {
                    Task { await HistoryStore.shared.runSelfTest() }
                }
                .keyboardShortcut("h", modifiers: [.command, .control, .option])
                #endif
            }
        }
    }
}
