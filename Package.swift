// swift-tools-version: 5.9

import Foundation
import PackageDescription

// Use system HDF5 (via Homebrew) instead of vendored XCFramework:
//   USE_SYSTEM_HDF5=1 swift build
//
// Default: vendored XCFramework (supports macOS + iPadOS, no brew required).
// System: uses whatever libhdf5 is installed (macOS only, useful for benchmarking).
let useSystemHDF5 = ProcessInfo.processInfo.environment["USE_SYSTEM_HDF5"] != nil

let chdf5Target: Target = useSystemHDF5
    ? .systemLibrary(
        name: "CHDF5",
        pkgConfig: "hdf5",
        providers: [.brew(["hdf5"])]
    )
    : .binaryTarget(
        name: "CHDF5",
        path: "Frameworks/CHDF5.xcframework"
    )

let package = Package(
    name: "sleap-io",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(name: "SleapIO", targets: ["SleapIO"]),
        .library(name: "SleapHDF5", targets: ["SleapHDF5"]),
        .library(name: "SleapVideo", targets: ["SleapVideo"]),
        .library(name: "SleapRendering", targets: ["SleapRendering"]),
        .executable(name: "sleapio", targets: ["SleapCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // HDF5 C library — either vendored XCFramework or system library.
        // XCFramework built by: Scripts/build-hdf5-xcframework.sh
        chdf5Target,

        // Core model types, codecs, transforms
        .target(
            name: "SleapIO",
            dependencies: []
        ),

        // HDF5 wrapper + SLP read/write + lazy loading
        .target(
            name: "SleapHDF5",
            dependencies: ["CHDF5", "SleapIO", "SleapVideo"]
        ),

        // Video abstraction + AVFoundation backend
        .target(
            name: "SleapVideo",
            dependencies: ["SleapIO"]
        ),

        // 2D pose overlay rendering
        .target(
            name: "SleapRendering",
            dependencies: ["SleapIO", "SleapVideo"]
        ),

        // CLI executable
        .executableTarget(
            name: "SleapCLI",
            dependencies: [
                "SleapHDF5",
                "SleapIO",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Tests
        .testTarget(
            name: "SleapIOTests",
            dependencies: ["SleapIO"]
        ),
        .testTarget(
            name: "SleapHDF5Tests",
            dependencies: ["SleapHDF5", "SleapIO", "SleapVideo"]
        ),
        .testTarget(
            name: "SleapVideoTests",
            dependencies: ["SleapVideo", "SleapIO"]
        ),
        .testTarget(
            name: "SleapRenderingTests",
            dependencies: ["SleapRendering", "SleapIO", "SleapVideo"]
        ),
        .testTarget(
            name: "SleapCLITests",
            dependencies: ["SleapIO"]
        ),
    ]
)
