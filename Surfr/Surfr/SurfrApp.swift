//
//  SurfrApp.swift
//  Surfr
//
//  Created by zeviter on 18/06/2026.
//

import SwiftUI
import AppKit

@main
struct SurfrApp: App {
    /// Drives the bookmark command's title (Bookmark ↔ Remove) from current state.
    @ObservedObject private var bookmarks = BookmarkState.shared
    /// Drives the trust command's title from the active domain's trust state.
    @ObservedObject private var trust = TrustStore.shared
    /// Source of effective shortcut bindings; observed so the menu updates if a
    /// future editor remaps a key (slice 9a — overrides empty by default).
    @ObservedObject private var shortcuts = ShortcutRegistry.shared

    /// The active tab's host if it's a real web page (http or https). Enables the
    /// trust command so ⌘⇧T is reachable even on an insecure page — the action is
    /// blocked in the handler (with a warning toast), not by disabling the menu.
    private var activeWebHost: String? {
        guard let url = bookmarks.activeURL, let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return host
    }

    /// Host only when it's an HTTPS page — used for the trust-state menu title (an
    /// http page is never trusted, so it always shows "Trust This Site").
    private var activeHTTPSHost: String? {
        guard let url = bookmarks.activeURL, url.scheme?.lowercased() == "https" else { return nil }
        return activeWebHost
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // All shortcuts route through ShortcutRegistry's effective bindings via
            // `.appShortcut(id, shortcuts)` — never hardcoded — so a future editor
            // can remap any of them and the menu updates.
            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .appShortcut(.newTab, shortcuts)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTab, object: nil)
                }
                .appShortcut(.closeTab, shortcuts)

                // ⌘W is authoritative for Close Tab (verified: AppKit's window-close
                // is auto-stripped of ⌘W and left shortcut-less). Give window-close
                // the browser-standard ⌘⇧W so it's still keyboard-reachable.
                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .appShortcut(.closeWindow, shortcuts)

                Divider()

                Button("Open Omnibox") {
                    NotificationCenter.default.post(name: .focusOmnibox, object: nil)
                }
                .appShortcut(.openLocation, shortcuts)

                Button("Reload Page") {
                    NotificationCenter.default.post(name: .reloadPage, object: nil)
                }
                .appShortcut(.reload, shortcuts)

                Button("Hard Reload (Bypass Cache)") {
                    NotificationCenter.default.post(name: .reloadHard, object: nil)
                }
                .appShortcut(.hardReload, shortcuts)

                Button("Empty Cache and Hard Reload") {
                    NotificationCenter.default.post(name: .reloadEmptyCache, object: nil)
                }
                .appShortcut(.emptyCacheReload, shortcuts)

                Button("Back") {
                    NotificationCenter.default.post(name: .goBack, object: nil)
                }
                .appShortcut(.back, shortcuts)

                Button("Forward") {
                    NotificationCenter.default.post(name: .goForward, object: nil)
                }
                .appShortcut(.forward, shortcuts)

                Divider()

                Button(bookmarks.isActiveBookmarked ? "Remove Bookmark" : "Bookmark Page") {
                    NotificationCenter.default.post(name: .toggleBookmark, object: nil)
                }
                .appShortcut(.bookmark, shortcuts)

                // Slice C1: trust the active site's domain so its session persists
                // (shared persistent store). Disabled when there's no real page.
                Button(trust.isTrusted(host: activeHTTPSHost)
                       ? "Stop Trusting This Site"
                       : "Trust This Site (Stay Logged In)") {
                    NotificationCenter.default.post(name: .toggleTrust, object: nil)
                }
                .appShortcut(.trustSite, shortcuts)
                .disabled(activeWebHost == nil)

                Divider()

                Button("History") {
                    NotificationCenter.default.post(name: .openHistory, object: nil)
                }
                .appShortcut(.history, shortcuts)

                Button("Trusted Sites") {
                    NotificationCenter.default.post(name: .openTrusted, object: nil)
                }
                .appShortcut(.trustedSites, shortcuts)

                Button("Downloads") {
                    NotificationCenter.default.post(name: .openDownloads, object: nil)
                }
                .appShortcut(.downloads, shortcuts)

                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .openShortcuts, object: nil)
                }
                .appShortcut(.shortcuts, shortcuts)

                Button("Vault") {
                    NotificationCenter.default.post(name: .openVault, object: nil)
                }
                .appShortcut(.vault, shortcuts)

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
