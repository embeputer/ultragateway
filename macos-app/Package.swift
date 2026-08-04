// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ultragateway-menubar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ultragateway-menubar", targets: ["ultragateway-menubar"])
    ],
    targets: [
        .executableTarget(
            name: "ultragateway-menubar",
            path: "Sources"
        )
    ]
)
