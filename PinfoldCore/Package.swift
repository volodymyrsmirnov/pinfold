// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PinfoldCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PinfoldCore", targets: ["PinfoldCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "PinfoldCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "PinfoldCoreTests",
            dependencies: ["PinfoldCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
