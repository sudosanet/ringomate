import Foundation

public enum ModelLibrary {
    static let limit = 24
    public static let extensions = ["zip", "rar", "pmx", "pmd", "vrm", "glb", "gltf", "fbx"]

    public static var bundled: [String] {
        [Bundle.main.path(forResource: "Tsukuyomi", ofType: "vrm", inDirectory: "tsukuyomi")].compactMap { $0 }
    }

    public static var all: [String] {
        let bundled = bundled
        let names = Set(bundled.map { URL(filePath: $0).lastPathComponent })
        let saved = (UserDefaults.standard.stringArray(forKey: SettingsKey.recentModels) ?? []).filter { path in
            !path.contains(".app/Contents/Resources/") || names.contains(URL(filePath: path).lastPathComponent)
        }.map { path in
            path.contains(".app/Contents/Resources/") && names.contains(URL(filePath: path).lastPathComponent)
                ? bundled.first { URL(filePath: $0).lastPathComponent == URL(filePath: path).lastPathComponent } ?? path
                : path
        }
        var seen = Set<String>()
        return (saved + bundled).filter { seen.insert($0).inserted }
    }

    public static func remember(_ paths: [String]) {
        let saved = UserDefaults.standard.stringArray(forKey: SettingsKey.recentModels) ?? []
        let merged = paths + saved.filter { !paths.contains($0) }
        UserDefaults.standard.set(Array(merged.prefix(limit)), forKey: SettingsKey.recentModels)
    }

    public static func forget(_ path: String) {
        let saved = UserDefaults.standard.stringArray(forKey: SettingsKey.recentModels) ?? []
        UserDefaults.standard.set(saved.filter { $0 != path }, forKey: SettingsKey.recentModels)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.recentModels)
    }

    public static func models(in folder: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }.map(\.path).sorted()
    }

    public static var current: String? { UserDefaults.standard.string(forKey: SettingsKey.lastModelPath) }
}
