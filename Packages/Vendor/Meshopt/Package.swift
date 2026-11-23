// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Meshopt",
    products: [.library(name: "CMeshopt", targets: ["CMeshopt"])],
    targets: [
        .target(name: "CMeshopt", path: ".", sources: ["meshoptimizer/src"], publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-O3", "-w"])]),
    ],
    cxxLanguageStandard: .cxx17
)
