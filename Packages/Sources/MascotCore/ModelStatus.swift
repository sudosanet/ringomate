import Foundation

public enum ModelStatus: String, Sendable {
    /// 読み込み前を含む。
    case installed
    case missing
    case failed
}

public func modelDirectory(_ name: String, marker: String) -> URL {
    let user = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/ringomate/models/\(name)")
    if FileManager.default.fileExists(atPath: user.appending(path: marker).path) { return user }
    guard let bundled = Bundle.main.resourceURL?.appending(path: "models/\(name)"),
          FileManager.default.fileExists(atPath: bundled.appending(path: marker).path) else { return user }
    return bundled
}
