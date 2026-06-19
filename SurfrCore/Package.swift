// swift-tools-version: 6.0
// SurfrCore — early seed of the eventual Phase-6 shared core (see docs/spec.md §6, docs/vault-spec.md §15).
// Slice 1 lands ONLY the headless vault crypto here: the vendored Argon2id reference C (`CArgon2`)
// and the import-clean `VaultCrypto` Swift layer (Foundation + CryptoKit only — no AppKit/SwiftUI/WebKit).
import PackageDescription

let package = Package(
    name: "SurfrCore",
    platforms: [
        .macOS(.v14),   // matches the app's deployment target
        .iOS(.v17),     // for the future iOS target / SurfrCore move
    ],
    products: [
        .library(name: "SurfrCore", targets: ["SurfrCore"]),
    ],
    targets: [
        // Vendored Argon2id reference C (phc-winner-argon2, tag 20190702). See Sources/CArgon2/VENDORED.md.
        // Portable `ref.c` only — no SIMD `opt.c`, no CLI tools. publicHeadersPath exposes argon2.h.
        .target(
            name: "CArgon2",
            exclude: ["LICENSE", "VENDORED.md"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "SurfrCore",
            dependencies: ["CArgon2"]
        ),
        .testTarget(
            name: "SurfrCoreTests",
            dependencies: ["SurfrCore"]
        ),
    ]
)
