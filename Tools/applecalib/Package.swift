// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "applecalib",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "applecalib",
            dependencies: [.product(name: "AccessLensTrackC", package: "Omnivision")]
        )
    ]
)
