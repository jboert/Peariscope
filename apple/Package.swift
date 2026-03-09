// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Peariscope",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "PeariscopeMac", targets: ["PeariscopeMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
    ],
    targets: [
        .target(
            name: "PeariscopeCore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "PeariscopeMac",
            dependencies: ["PeariscopeCore"]
        ),
        .target(
            name: "PeariscopeIOS",
            dependencies: ["PeariscopeCore"]
        ),
    ]
)
