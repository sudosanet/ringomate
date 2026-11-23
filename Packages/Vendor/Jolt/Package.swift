// swift-tools-version: 6.4
// JoltPhysics/ は git submodule。JPH_OBJECT_LAYER_BITS は CJolt と同じにする。
import PackageDescription

let package = Package(
    name: "Jolt",
    products: [.library(name: "Jolt", targets: ["Jolt"])],
    targets: [
        .target(
            name: "Jolt",
            path: ".",
            exclude: [
                "JoltPhysics/Assets", "JoltPhysics/Build", "JoltPhysics/Docs", "JoltPhysics/HelloWorld", "JoltPhysics/JoltViewer",
                "JoltPhysics/PerformanceTest", "JoltPhysics/Samples", "JoltPhysics/TestFramework", "JoltPhysics/UnitTests",
                "JoltPhysics/Jolt/Compute/CPU", "JoltPhysics/Jolt/Compute/DX12", "JoltPhysics/Jolt/Compute/MTL",
                "JoltPhysics/Jolt/Compute/VK", "JoltPhysics/Jolt/Shaders", "JoltPhysics/Jolt/Jolt.cmake",
                "JoltPhysics/Jolt/Jolt.natvis",
                "JoltPhysics/Jolt/ObjectStream/ObjectStream.cpp", "JoltPhysics/Jolt/ObjectStream/ObjectStreamBinaryIn.cpp",
                "JoltPhysics/Jolt/ObjectStream/ObjectStreamBinaryOut.cpp", "JoltPhysics/Jolt/ObjectStream/ObjectStreamIn.cpp",
                "JoltPhysics/Jolt/ObjectStream/ObjectStreamOut.cpp", "JoltPhysics/Jolt/ObjectStream/ObjectStreamTextIn.cpp",
                "JoltPhysics/Jolt/ObjectStream/ObjectStreamTextOut.cpp", "JoltPhysics/Jolt/ObjectStream/TypeDeclarations.cpp",
            ],
            sources: ["JoltPhysics/Jolt"],
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("JoltPhysics"), .define("JPH_OBJECT_LAYER_BITS", to: "32"),
                          .unsafeFlags(["-O3", "-w", "-UDEBUG", "-fno-rtti"])]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
