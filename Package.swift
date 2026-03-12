// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "sleap-io",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
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
        // C shim for libhdf5 — exposes HDF5 macros as inline functions
        .systemLibrary(
            name: "CHDF5",
            pkgConfig: "hdf5",
            providers: [
                .brew(["hdf5"]),
            ]
        ),

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
