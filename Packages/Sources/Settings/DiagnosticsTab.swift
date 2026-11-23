import AppKit
import SwiftUI

struct DiagnosticsTab: View {
    let actions: SettingsActions
    @AppStorage(SettingsKey.diagnostics) private var enabled = false
    @AppStorage(SettingsKey.boneAssist) private var boneAssist = true
    @State private var lines: [String] = []
    @State private var status: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if !status.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(status, id: \.self) { Text($0) }
                }
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 12)
            }
            Toggle(isOn: $enabled) {
                Text("Enable diagnostics", bundle: #bundle)
                Text("Collects from the next model load. It slows things down, so use it only when troubleshooting", bundle: #bundle)
            }
            .padding([.horizontal, .top], 12)
            .onChange(of: enabled) { lines = enabled ? actions.diagnostics() : [] }
            Toggle(isOn: $boneAssist) {
                Text("Ask the AI for missing bone candidates", bundle: #bundle)
                Text("Uses on-device AI to add likely standard bone names to the diagnostics", bundle: #bundle)
            }
            .padding(12)
            .disabled(!enabled)
            Divider()
            ScrollView {
                Text(!enabled ? String(localized: "Disabled", bundle: #bundle) : lines.isEmpty ? String(localized: "No model loaded yet", bundle: #bundle) : lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack {
                Button {
                    status = actions.aiStatus()
                    lines = actions.diagnostics()
                } label: { label("Refresh", "arrow.clockwise") }
                Spacer()
                Button { copy() } label: { label("Copy", "doc.on.doc") }
                Button { saveAndOpen() } label: { label("Write to File and Open", "doc.text") }
            }
            .padding(12)
            .disabled(!enabled)
        }
        .onAppear {
            status = actions.aiStatus()
            lines = enabled ? actions.diagnostics() : []
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((status + lines).joined(separator: "\n"), forType: .string)
    }

    private func saveAndOpen() {
        let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/ringomate/diagnostics.txt")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? (status + lines).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(file)
    }
}
