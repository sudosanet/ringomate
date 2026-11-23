import Foundation

/// 外部のコマンドを動かして標準出力を返す。起動できなければ nil。
/// 出力を読み切ってから終わりを待つ（逆だとパイプが詰まって止まる）。
public func runTool(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(filePath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// `com.hnc.Discord.helper.Renderer` → `com.hnc.Discord`
public func appBundleBase(_ id: String) -> String { id.range(of: ".helper").map { String(id[..<$0.lowerBound]) } ?? id }
