// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HeadPrivacy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeadPrivacyCore", targets: ["HeadPrivacyCore"]),
        .library(name: "HeadPrivacyMac", targets: ["HeadPrivacyMac"]),
        .executable(name: "HeadPrivacyApp", targets: ["HeadPrivacyApp"]),
    ],
    targets: [
        .target(name: "HeadPrivacyCore"),
        .target(name: "HeadPrivacyMac", dependencies: ["HeadPrivacyCore"]),
        .executableTarget(name: "HeadPrivacyApp", dependencies: ["HeadPrivacyCore", "HeadPrivacyMac"]),
        .testTarget(name: "HeadPrivacyCoreTests", dependencies: ["HeadPrivacyCore"]),
    ]
)
