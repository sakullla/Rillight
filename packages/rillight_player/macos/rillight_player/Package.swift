// swift-tools-version: 5.9

import PackageDescription

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
                .headerSearchPath("include/rillight_player")
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("rillight_core")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
