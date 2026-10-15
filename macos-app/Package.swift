// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ultragateway-menubar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ultragateway-menubar", targets: ["ultragateway-menubar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1")
    ],
    targets: [
        .executableTarget(
            name: "ultragateway-menubar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources"
        )
    ]
)
