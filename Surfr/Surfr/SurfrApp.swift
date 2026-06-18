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
                Button("Open Location…") {
                    NotificationCenter.default.post(name: .focusOmnibox, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}
