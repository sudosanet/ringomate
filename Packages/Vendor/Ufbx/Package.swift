// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Ufbx",
    products: [.library(name: "CUfbx", targets: ["CUfbx"])],
    targets: [
        .target(name: "CUfbx", path: ".", sources: ["ufbx/ufbx.c"], publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-O2", "-w"])]),
    ]
)
