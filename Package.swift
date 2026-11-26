// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Renoo",
    platforms: [
        .iOS(.v17),
        // macOS is only here so core logic can be unit-tested with `swift test`.
        .macOS(.v14),
    ],
    products: [
        .library(name: "Renoo", targets: ["Renoo"])
    ],
    targets: [
        .target(
            name: "Renoo",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "RenooTests",
            dependencies: ["Renoo"]
        ),
    ]
)
