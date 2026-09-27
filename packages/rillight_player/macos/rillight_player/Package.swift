// swift-tools-version: 5.9

import Foundation
import PackageDescription

// The verified core and FFmpeg dylibs are staged by prepare_macos.py before
// Flutter builds the app. bundle_macos.py copies the same hashed libraries into
// the app, so SwiftPM must link the staged core rather than fetch another one.
let libraries = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Libraries")
    .path

let package = Package(
    name: "rillight_player",
    platforms: [.macOS("12.0")],
    products: [
        .library(name: "rillight-player", targets: ["rillight_player"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "rillight_player",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            path: "Sources/rillight_player",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedLibrary("rillight_core"),
                .unsafeFlags(["-L\(libraries)"])
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
