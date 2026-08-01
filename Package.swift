// swift-tools-version:5.9
// AccessLens Social — Track C (extraction algorithms).
//
// This package holds ONLY the portable, hardware-independent half of Track C so that it can be
// built and tested on Linux. It deliberately contains no AVFoundation, Speech, Vision, or Meta DAT
// code. See docs/TRACK_C.md for the integration path into the iOS app target.

import PackageDescription

let package = Package(
    name: "AccessLensTrackC",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "AccessLensTrackC", targets: ["AccessLensTrackC"])
    ],
    targets: [
        .target(name: "AccessLensTrackC"),
        .testTarget(
            name: "AccessLensTrackCTests",
            dependencies: ["AccessLensTrackC"]
        )
    ]
)
