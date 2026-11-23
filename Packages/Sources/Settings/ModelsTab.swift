import AppKit
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class ModelListStore {
    private(set) var paths: [String] = []
    private(set) var current: String?
    private(set) var details: [String: ModelDetails] = [:]
    private(set) var thumbnailVersion = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var asked = Set<String>()
    @ObservationIgnored private let actions: SettingsActions

    init(actions: SettingsActions) {
        self.actions = actions
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: ModelThumbnails.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thumbnailVersion += 1 }
        })
    }

    func refresh() {
        let p = ModelLibrary.all, c = ModelLibrary.current
        if p != paths { paths = p }
        if c != current { current = c }
        fill()
    }

    private func fill() {
        let missing = paths.filter { !asked.contains($0) && FileManager.default.fileExists(atPath: $0) }
        guard !missing.isEmpty else { return }
        asked.formUnion(missing)
        for path in missing where ModelThumbnails.image(for: path) == nil { actions.makeThumbnail(path) }
        Task { [weak self, actions] in
            for path in missing {
                guard let d = await actions.details(path) else { continue }
                self?.details[path] = d
            }
        }
    }

    /// 表示の言語が日本語でなければ、モデルの英語名を先に使う。
    func title(_ path: String) -> String {
        let d = details[path]
        let names = Bundle.main.preferredLocalizations.first == "ja" ? [d?.title, d?.titleEn] : [d?.titleEn, d?.title]
        return names.compactMap { $0 }.first { !$0.isEmpty } ?? URL(filePath: path).deletingPathExtension().lastPathComponent
    }

    /// `title` に使わなかったほうの名前（同じなら nil）。
    func otherTitle(_ path: String) -> String? {
        guard let d = details[path] else { return nil }
        let shown = title(path)
        return [d.title, d.titleEn].first { !$0.isEmpty && $0 != shown }
    }
}

struct ModelsTab: View {
    let actions: SettingsActions
    let store: ModelListStore
    @State private var selected: String?
    @State private var message: String?

    private var status: LoadStatus { actions.status }
    private var pending: String? { status.path }

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 140), spacing: 10)]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.paths, id: \.self) { path in
                            ModelCard(path: path, title: store.title(path), format: store.details[path]?.format,
                                      isCurrent: path == store.current, isSelected: path == shown,
                                      progress: path == pending ? status.fraction : nil, thumbnailVersion: store.thumbnailVersion)
                                .onTapGesture(count: 2) { load(path) }
                                .onTapGesture { selected = path }
                                .contextMenu { menu(for: path) }
                        }
                    }
                    .padding(12)
                }
                Divider()
                footer
            }
            .frame(minWidth: 300)
            Divider()
            if let shown {
                ModelDetailView(path: shown, store: store, isCurrent: shown == store.current,
                                status: shown == pending ? status : nil, load: { load(shown) }, reload: actions.reload)
                    .frame(width: 330)
                    .id(shown)
            }
        }
        .onChange(of: status.failure) {
            guard let failure = status.failure else { return }
            message = failure
            status.failure = nil
        }
        .alert(message ?? "", isPresented: Binding { message != nil } set: { if !$0 { message = nil } }) {
            Button { message = nil } label: { Text(verbatim: "OK") }
        }
    }

    private var shown: String? { selected.flatMap { store.paths.contains($0) ? $0 : nil } ?? store.current ?? store.paths.first }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending {
                LoadProgressView(title: String(localized: "Loading: \(store.title(pending))", bundle: #bundle), status: status)
            } else if status.thumbnailsLeft > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Making thumbnails and details (\(status.thumbnailsLeft) left)", bundle: #bundle).font(.caption).foregroundStyle(.secondary)
                }
            }
            buttons
        }
        .padding(12)
    }

    private var buttons: some View {
        HStack {
            Button { openModel() } label: { label("Load from File…", "doc.badge.plus") }
            Button { addFolder() } label: { label("Add Folder…", "folder.badge.plus") }
            Spacer()
        }
        .disabled(pending != nil)
    }

    @ViewBuilder private func menu(for path: String) -> some View {
        Button { load(path) } label: { Text("Load", bundle: #bundle) }
        if !ModelLibrary.bundled.contains(path) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) } label: { Text("Show in Finder", bundle: #bundle) }
            Divider()
            Button { ModelLibrary.forget(path) } label: { Text("Remove from List", bundle: #bundle) }
        }
        Divider()
        Button { ModelLibrary.clear() } label: { Text("Clear List (Keeps Bundled Models)", bundle: #bundle) }
    }

    private func load(_ path: String) {
        selected = path
        guard path != store.current, FileManager.default.fileExists(atPath: path) else { return }
        actions.loadModel(path)
    }

    private func openModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ModelLibrary.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url.path)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = String(localized: "Adds all models in the folder (ZIP, PMX, PMD, VRM, GLB, glTF, FBX) to the list", bundle: #bundle)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let found = ModelLibrary.models(in: dir)
        if found.isEmpty { message = String(localized: "No models found", bundle: #bundle); return }
        ModelLibrary.remember(found)
        message = String(localized: "Added \(found.count) models to the list", bundle: #bundle)
    }
}

private struct ModelDetailView: View {
    let path: String
    let store: ModelListStore
    let isCurrent: Bool
    let status: LoadStatus?
    let load: () -> Void
    let reload: () -> Void

    private var isLoading: Bool { status != nil }
    private var url: URL { URL(filePath: path) }
    private var details: ModelDetails? { store.details[path] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    ModelIcon(path: path, thumbnailVersion: store.thumbnailVersion)
                        .frame(width: 150, height: 150)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.title(path)).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if let other = store.otherTitle(path) {
                        Text(other).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(path)
                }
                HStack {
                    if isCurrent {
                        Button(action: reload) { Text("Reload (Reset)", bundle: #bundle) }
                            .disabled(isLoading)
                            .help(Text("Returns the model to its initial state when it looks broken", bundle: #bundle))
                    } else {
                        Button(action: load) { Text("Load", bundle: #bundle) }
                            .disabled(isLoading)
                            .keyboardShortcut(.defaultAction)
                    }
                    if !ModelLibrary.bundled.contains(path) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Text("Show in Finder", bundle: #bundle) }
                        Button { ModelLibrary.forget(path) } label: { Text("Remove from List", bundle: #bundle) }
                    }
                }
                .controlSize(.small)
                if let status { LoadProgressView(title: String(localized: "Loading", bundle: #bundle), status: status) }
                if let details {
                    info(details)
                    if !details.comment.isEmpty { section(String(localized: "Comment", bundle: #bundle), details.comment, expanded: details.terms.isEmpty) }
                    ForEach(Array(details.terms.enumerated()), id: \.offset) { i, t in
                        section(String(localized: "Terms: \(t.name)", bundle: #bundle), t.text, expanded: i == 0)
                    }
                    if details.terms.isEmpty {
                        Text("No terms file found (check the comment and the distribution page too)", bundle: #bundle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if FileManager.default.fileExists(atPath: path) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("File not found", bundle: #bundle).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }

    private func info(_ d: ModelDetails) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row(String(localized: "Format", bundle: #bundle), d.format + (["zip", "rar"].contains(url.pathExtension.lowercased()) ? "（\(url.pathExtension.uppercased())）" : ""))
            if d.decisions.isEmpty, !d.profile.isEmpty { row(String(localized: "Profile", bundle: #bundle), d.profile) }
            ForEach(d.decisions, id: \.item) { x in
                GridRow {
                    Text(x.item).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(x.value.isEmpty ? "—" : x.value).lineLimit(2).truncationMode(.tail)
                        Text([x.source, x.reason].filter { !$0.isEmpty }.joined(separator: "・")).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            ForEach(d.counts, id: \.label) { c in row(c.label, c.value.formatted()) }
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                row(String(localized: "File size", bundle: #bundle), ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))
            }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func section(_ title: String, _ text: String, expanded: Bool) -> some View {
        DisclosureSection(title: title, text: text, initiallyExpanded: expanded)
    }
}

private struct DisclosureSection: View {
    let title: String
    let text: String
    @State private var expanded: Bool

    init(title: String, text: String, initiallyExpanded: Bool) {
        (self.title, self.text) = (title, text)
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        } label: {
            Text(title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct ModelCard: View {
    let path: String
    let title: String
    let format: String?
    let isCurrent: Bool
    let isSelected: Bool
    let progress: Double?
    let thumbnailVersion: Int

    private var url: URL { URL(filePath: path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ModelIcon(path: path, thumbnailVersion: thumbnailVersion)
                    .frame(width: 96, height: 96)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small).padding(6)
                } else if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title3)
                        .padding(4)
                }
            }
            Text(title)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(!exists ? String(localized: "Not found", bundle: #bundle) : ModelLibrary.bundled.contains(path) ? String(localized: "\(format ?? url.pathExtension.uppercased()) · Bundled", bundle: #bundle) : format ?? url.pathExtension.uppercased())
                .font(.caption2)
                .foregroundStyle(exists ? Color.secondary : Color.red)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(isSelected ? Color.accentColor.opacity(0.12) : .clear))
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .opacity(exists ? 1 : 0.5)
        .help(path)
    }
}

private struct LoadProgressView: View {
    let title: String
    let status: LoadStatus

    var body: some View {
        ProgressView(value: status.fraction) {
            Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
        } currentValueLabel: {
            Text(verbatim: "\(status.stage.isEmpty ? String(localized: "Preparing", bundle: #bundle) : status.stage)… \(status.fraction.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption2).monospacedDigit()
        }
    }
}

struct ModelIcon: View {
    let path: String
    let thumbnailVersion: Int

    var body: some View {
        if let image = ModelThumbnails.image(for: path), thumbnailVersion >= 0 {
            Image(nsImage: image).resizable().scaledToFit().padding(4)
        } else {
            Image(systemName: Self.symbol(for: URL(filePath: path).pathExtension.lowercased()))
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
        }
    }

    static func symbol(for ext: String) -> String {
        switch ext {
        case "vrm": "person.crop.circle"
        case "zip", "rar": "doc.zipper"
        case "glb", "gltf", "fbx": "cube"
        default: "figure.stand"
        }
    }
}
