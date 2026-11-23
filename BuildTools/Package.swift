// swift-tools-version: 6.4
// 開発の道具（アプリには入らない）: swift run --package-path BuildTools xcodegen
import PackageDescription

let package = Package(
    name: "BuildTools",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/yonaskolb/XcodeGen.git", exact: "2.46.0")],
    targets: []
)
