// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LuximioLinks",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "LuximioLinks", targets: ["LuximioLinks"]),
        .library(name: "LuximioLinksAppClip", targets: ["LuximioLinks"]),
    ],
    targets: [
        .target(name: "LuximioLinks", resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .testTarget(name: "LuximioLinksTests", dependencies: ["LuximioLinks"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
