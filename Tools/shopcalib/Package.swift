// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "shopcalib",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "shopcalib",
            dependencies: [.product(name: "AccessLensTrackC", package: "Omnivision")]
        )
    ]
)
