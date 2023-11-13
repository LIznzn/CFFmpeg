// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CFFmpeg",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "CFFmpeg",
            targets: ["CFFmpeg"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CFFmpeg",
            dependencies: ["libavcodec", "libavfilter","libavformat","libavutil","libswresample","libswscale","libavdevice"],
            publicHeadersPath: "include"),
        .binaryTarget(
            name: "libavcodec",
            path: "Frameworks/libavcodec.xcframework"),
        .binaryTarget(
            name: "libavfilter",
            path: "Frameworks/libavfilter.xcframework"),
        .binaryTarget(
            name: "libavformat",
            path: "Frameworks/libavformat.xcframework"),
        .binaryTarget(
            name: "libavutil",
            path: "Frameworks/libavutil.xcframework"),
        .binaryTarget(
            name: "libswresample",
            path: "Frameworks/libswresample.xcframework"),
        .binaryTarget(
            name: "libswscale",
            path: "Frameworks/libswscale.xcframework"),
        .binaryTarget(
            name: "libavdevice",
            path: "Frameworks/libavdevice.xcframework"),
        .testTarget(
            name: "CFFmpegTests",
            dependencies: ["CFFmpeg"]),
    ]
)
