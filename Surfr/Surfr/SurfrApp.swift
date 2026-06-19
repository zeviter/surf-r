//
//  SurfrApp.swift
//  Surfr
//
//  Created by zeviter on 18/06/2026.
//

import SwiftUI

@main
struct SurfrApp: App {
    /// Drives the bookmark command's title (Bookmark ↔ Remove) from current state.
    @ObservedObject private var bookmarks = BookmarkState.shared
    /// Drives the trust command's title from the active domain's trust state.
    @ObservedObject private var trust = TrustStore.shared

    /// The active tab's host (tracked via `BookmarkState.activeURL`), if it's a
    /// real web page the trust command can act on.
    private var activeHost: String? {
        guard let url = bookmarks.activeURL, let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return host
    }

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

                Button(bookmarks.isActiveBookmarked ? "Remove Bookmark" : "Bookmark Page") {
                    NotificationCenter.default.post(name: .toggleBookmark, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                // Slice C1: trust the active site's domain so its session persists
                // (shared persistent store). Disabled when there's no real page.
                Button(trust.isTrusted(host: activeHost)
                       ? "Stop Trusting This Site"
                       : "Trust This Site (Stay Logged In)") {
                    NotificationCenter.default.post(name: .toggleTrust, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(activeHost == nil)

                // Addition 3: keyboard back/forward (was missing). Pairs with the
                // swipe-gesture and mouse side-button paths wired in ContentView.
                Button("Back") {
                    NotificationCenter.default.post(name: .goBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    NotificationCenter.default.post(name: .goForward, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)

                #if DEBUG
                Button("Run History Self-Test") {
                    Task { await HistoryStore.shared.runSelfTest() }
                }
                .keyboardShortcut("h", modifiers: [.command, .control, .option])

                Button("Run Bookmark Self-Test") {
                    Task { await BookmarkStore.shared.runSelfTest() }
                }
                .keyboardShortcut("b", modifiers: [.command, .control, .option])

                Button("Run Favicon Self-Test") {
                    Task { await FaviconService.shared.runSelfTest() }
                }
                .keyboardShortcut("f", modifiers: [.command, .control, .option])
                #endif
            }
        }
    }
}
