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
            dependencies: ["CHDF5", "SleapIO"]
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

        // Tests
        .testTarget(
            name: "SleapIOTests",
            dependencies: ["SleapIO"]
        ),
        .testTarget(
            name: "SleapHDF5Tests",
            dependencies: ["SleapHDF5", "SleapIO"]
        ),
        .testTarget(
            name: "SleapVideoTests",
            dependencies: ["SleapVideo", "SleapIO"]
        ),
        .testTarget(
            name: "SleapRenderingTests",
            dependencies: ["SleapRendering", "SleapIO"]
        ),
    ]
)
