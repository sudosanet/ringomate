// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MascotPackages",
    defaultLocalization: "en",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Overlay", targets: ["Overlay"]),
        .library(name: "Behavior", targets: ["Behavior"]),
        .library(name: "Agent", targets: ["Agent"]),
        .library(name: "MascotCore", targets: ["MascotCore"]),
        .library(name: "Listen", targets: ["Listen"]),
        .library(name: "Senses", targets: ["Senses"]),
        .library(name: "Render", targets: ["Render"]),
        .library(name: "CoreBridge", targets: ["CoreBridge"]),
        .library(name: "Settings", targets: ["Settings"]),
        .library(name: "AI", targets: ["AI"]),
        .library(name: "Voice", targets: ["Voice"]),
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "Update", targets: ["Update"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/LebJe/TOMLKit.git", .upToNextMinor(from: "0.6.0")),
        // モジュールの import のルール（.swiftlint.yml）: swift package plugin swiftlint
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins.git", exact: "0.65.1"),
        // 上流に Package.swift がない C/C++ は git submodule をローカルパッケージで包む
        .package(url: "https://github.com/sudosanet/swift-irodori-tts.git", .upToNextMinor(from: "0.1.0")),
        .package(path: "Vendor/Jolt"),
        .package(path: "Vendor/Ufbx"),
        .package(path: "Vendor/Meshopt"),
    ],
    targets: [
        .target(name: "Overlay", dependencies: ["Render", "MascotCore"]),
        .target(name: "Agent", dependencies: ["MascotCore", "HookWire"]),
        .target(name: "HookWire"),
        .target(name: "Behavior", dependencies: ["MascotCore", "Engine"]),
        .target(name: "AI", dependencies: ["MascotCore"]),
        .target(name: "Voice", dependencies: ["MascotCore", .product(name: "IrodoriTTS", package: "swift-irodori-tts")]),
        .target(name: "Settings", dependencies: ["HookWire"], resources: [.copy("Licenses")]),
        .target(name: "Render"),
        .target(name: "CoreBridge", dependencies: ["Engine", "Render"]),
        .target(name: "MascotCore"),
        .target(name: "Listen", dependencies: ["MascotCore"]),
        .target(name: "Senses", dependencies: ["MascotCore"]),
        .target(name: "Update"),
        // 最適化なしでは毎フレームの評価が間に合わないので Debug でも -O
        .target(
            name: "Engine",
            dependencies: ["CJolt", .product(name: "CUfbx", package: "Ufbx"), .product(name: "CMeshopt", package: "Meshopt"),
                           .product(name: "TOMLKit", package: "TOMLKit")],
            resources: [.copy("Profiles")],
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug)), .unsafeFlags(["-enforce-exclusivity=unchecked"])],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // define は Vendor/Jolt と同じにする（違うと構造体の形がずれる）
        .target(
            name: "CJolt",
            dependencies: [.product(name: "Jolt", package: "Jolt")],
            cxxSettings: [.headerSearchPath("../../Vendor/Jolt/JoltPhysics"), .define("JPH_OBJECT_LAYER_BITS", to: "32"), .unsafeFlags(["-O3", "-w", "-UDEBUG", "-fno-rtti"])]
        ),
        .executableTarget(name: "mascot-hook", dependencies: ["HookWire", .product(name: "MCP", package: "swift-sdk")]),

        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),
        .testTarget(name: "AgentTests", dependencies: ["Agent"]),
        .testTarget(name: "BehaviorTests", dependencies: ["Behavior"]),
        .testTarget(name: "AITests", dependencies: ["AI"]),
        .testTarget(name: "VoiceTests", dependencies: ["Voice"]),
        .testTarget(name: "SettingsTests", dependencies: ["Settings"]),
        .testTarget(name: "MascotCoreTests", dependencies: ["MascotCore"]),
        .testTarget(name: "ListenTests", dependencies: ["Listen"]),
        .testTarget(name: "SensesTests", dependencies: ["Senses"]),
        .testTarget(name: "UpdateTests", dependencies: ["Update"]),
        .testTarget(name: "CoreBridgeTests", dependencies: ["CoreBridge", "Render"]),
        .testTarget(name: "EngineTests", dependencies: ["Engine"], exclude: ["Corpus", "Baselines"]),
        .testTarget(name: "HookTests", dependencies: ["mascot-hook", "HookWire", "Behavior", .product(name: "MCP", package: "swift-sdk")]),
    ],
    cxxLanguageStandard: .cxx17
)
