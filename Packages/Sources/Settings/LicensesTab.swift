import AppKit
import SwiftUI

struct ThirdPartyItem: Identifiable, Hashable {
    enum Kind: CaseIterable {
        case character, motion, prop, model, library, port

        var title: String {
            switch self {
            case .character: String(localized: "Characters", bundle: #bundle)
            case .motion: String(localized: "Motions", bundle: #bundle)
            case .prop: String(localized: "Props", bundle: #bundle)
            case .model: String(localized: "AI models", bundle: #bundle)
            case .library: String(localized: "Libraries", bundle: #bundle)
            case .port: String(localized: "Ported code", bundle: #bundle)
            }
        }

        var symbol: String {
            switch self {
            case .character: "person.fill"
            case .motion: "figure.dance"
            case .prop: "chair.lounge.fill"
            case .model: "waveform"
            case .library: "shippingbox.fill"
            case .port: "chevron.left.forwardslash.chevron.right"
            }
        }

        var color: Color {
            switch self {
            case .character: .pink
            case .motion: .orange
            case .prop: .brown
            case .model: .purple
            case .library: .blue
            case .port: .teal
            }
        }
    }

    let kind: Kind
    let name: String
    let author: String
    let license: String
    let url: String
    var credit: String?
    /// Licenses/ の中のファイル名。`bundle:` で始まればアプリのバンドルの中のパス。
    var text: String?

    var id: String { name }

    var fullText: String? {
        guard let text else { return nil }
        let url = text.hasPrefix("bundle:")
            ? Bundle.main.resourceURL?.appending(path: String(text.dropFirst(7)))
            : Bundle.module.url(forResource: text, withExtension: "txt", subdirectory: "Licenses")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

extension ThirdPartyItem {
    static let all: [ThirdPartyItem] = [
        .init(kind: .character, name: "つくよみちゃん公式3Dモデル タイプA", author: "夢前黎（Rei Yumesaki）",
              license: "つくよみちゃんキャラクターライセンス", url: "https://tyc.rei-yumesaki.net/material/avatar/3d-a/",
              credit: "本ソフトウェアでは、フリー素材キャラクター「つくよみちゃん」（© Rei Yumesaki）を使用しています。本ソフトウェアに収録されているつくよみちゃんの3Dモデルの利用規約は、「つくよみちゃん公式3Dモデル タイプA」の利用規約（https://tyc.rei-yumesaki.net/material/avatar/3d-a/）に準じます。本ソフトウェアのつくよみちゃんを使ったコンテンツを公開するときは、つくよみちゃんキャラクターライセンス（https://tyc.rei-yumesaki.net/about/terms/）に従ってください。",
              text: "bundle:tsukuyomi/利用規約.txt"),
        .init(kind: .motion, name: "Universal Animation Library", author: "Quaternius", license: "CC0 1.0",
              url: "https://quaternius.itch.io/universal-animation-library"),
        .init(kind: .motion, name: "Universal Animation Library 2", author: "Quaternius", license: "CC0 1.0",
              url: "https://quaternius.itch.io/universal-animation-library-2"),
        .init(kind: .motion, name: "Bandai Namco Research Motion Dataset 1・2", author: "Bandai Namco Research Inc.", license: "CC BY-NC 4.0",
              url: "https://github.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset",
              credit: "Bandai-Namco-Research-Motiondataset (c) Bandai Namco Research Inc., licensed under CC BY-NC 4.0. Retargeted and trimmed for this app.", text: "bandai"),
        .init(kind: .motion, name: "CMU Graphics Lab Motion Capture Database", author: "Carnegie Mellon University (BVH conversion: Bruce Hahne)",
              license: "CMU terms of use", url: "http://mocap.cs.cmu.edu",
              credit: "The data used in this project was obtained from mocap.cs.cmu.edu. The database was created with funding from NSF EIA-0196217.",
              text: "cmu"),
        .init(kind: .motion, name: "愛包ダンスホール モーション", author: "HIMEHINA（Studio LaRa）", license: "HIMEHINA creative guidelines",
              url: "https://himehina.jp/guideline",
              credit: "Song, choreography and motion: HIMEHINA (Studio LaRa). Official AipaiDanceHall_Motion(MMD)_Full_HimeTanaka_v1.1"),
        .init(kind: .motion, name: "強風オールバック MV 再現モーション", author: "MoNo (the skip is adapted from susuki's 「歩いたり走ったりスキップしたり ver3.0」)",
              license: "Distribution terms (modification and redistribution allowed)", url: "https://www.nicovideo.jp/watch/sm42210576", text: "kyofu-allback"),
        .init(kind: .prop, name: "KayKit Furniture Bits", author: "Kay Lousberg", license: "CC0 1.0",
              url: "https://github.com/KayKit-Game-Assets/KayKit-Furniture-Bits-1.0", text: "kaykit"),
        .init(kind: .model, name: "Beat This!（small0）", author: "Institute of Computational Perception, JKU Linz", license: "MIT",
              url: "https://github.com/CPJKU/beat_this", text: "beat-this"),
        .init(kind: .model, name: "LAION-CLAP（music_audioset_epoch_15_esc_90.14）", author: "LAION", license: "Apache-2.0",
              url: "https://github.com/LAION-AI/CLAP", text: "apache-2.0"),
        .init(kind: .model, name: "Irodori-TTS v4.1 Small MF", author: "Aratako", license: "MIT",
              url: "https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF", text: "irodori-tts"),
        .init(kind: .model, name: "ModernBERT-ja-310m", author: "SB Intuitions", license: "MIT",
              url: "https://huggingface.co/sbintuitions/modernbert-ja-310m", text: "modernbert-ja"),
        .init(kind: .model, name: "Semantic-DACVAE-Japanese-32dim", author: "Aratako", license: "MIT",
              url: "https://huggingface.co/Aratako/Semantic-DACVAE-Japanese-32dim", text: "semantic-dacvae"),
        .init(kind: .model, name: "DACVAE", author: "Meta Platforms, Inc.", license: "Apache-2.0",
              url: "https://github.com/facebookresearch/dacvae", text: "apache-2.0"),
        .init(kind: .library, name: "Jolt Physics", author: "Jorrit Rouwe", license: "MIT", url: "https://github.com/jrouwe/JoltPhysics", text: "jolt"),
        .init(kind: .library, name: "ufbx", author: "Samuli Raivio", license: "MIT / Unlicense", url: "https://github.com/ufbx/ufbx", text: "ufbx"),
        .init(kind: .library, name: "meshoptimizer", author: "Arseny Kapoulkine", license: "MIT", url: "https://github.com/zeux/meshoptimizer",
              text: "meshoptimizer"),
        .init(kind: .library, name: "swift-irodori-tts", author: "sudosanet", license: "Apache-2.0",
              url: "https://github.com/sudosanet/swift-irodori-tts", text: "apache-2.0"),
        .init(kind: .library, name: "TOMLKit", author: "Jeff Lebrun", license: "MIT", url: "https://github.com/LebJe/TOMLKit", text: "tomlkit"),
        .init(kind: .library, name: "toml++", author: "Mark Gillard", license: "MIT", url: "https://github.com/marzer/tomlplusplus",
              text: "tomlplusplus"),
        .init(kind: .port, name: "mmd-anim", author: "Yohawing", license: "MIT", url: "https://github.com/yohawing/mmd-anim", text: "mmd-anim"),
        .init(kind: .port, name: "Chromaprint", author: "Lukas Lalinsky", license: "MIT", url: "https://github.com/acoustid/chromaprint",
              text: "chromaprint"),
        .init(kind: .port, name: "rusty-chromaprint", author: "darksv", license: "MIT", url: "https://github.com/darksv/rusty-chromaprint",
              text: "rusty-chromaprint"),
        .init(kind: .port, name: "rubato", author: "Henrik Enquist", license: "MIT", url: "https://github.com/HEnquist/rubato", text: "rubato"),
    ]
}

struct LicensesTab: View {
    @State private var selection: ThirdPartyItem.ID?
    @State private var query = ""

    init(initial: ThirdPartyItem.ID? = ThirdPartyItem.all.first?.id) {
        _selection = State(initialValue: initial)
    }

    private var filtered: [ThirdPartyItem] {
        query.isEmpty ? ThirdPartyItem.all : ThirdPartyItem.all.filter {
            "\($0.name) \($0.author) \($0.license)".localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField(text: $query, prompt: Text("Search", bundle: #bundle)) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(ThirdPartyItem.Kind.allCases, id: \.self) { kind in
                            let items = filtered.filter { $0.kind == kind }
                            if !items.isEmpty {
                                Text(kind.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
                                ForEach(items) { item in
                                    Button { selection = item.id } label: {
                                        LicenseRow(item: item, selected: selection == item.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .background(Color.primary.opacity(0.035))
                Text("Rights to loaded models belong to their authors. Use them according to each model's terms.", bundle: #bundle)
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(width: 270)
            Divider()
            if let item = ThirdPartyItem.all.first(where: { $0.id == selection }) {
                LicenseDetail(item: item).id(item.id)
            } else {
                ContentUnavailableView { label("Select an Item", "doc.text") }
            }
        }
    }
}

private struct LicenseRow: View {
    let item: ThirdPartyItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            SettingsIcon(symbol: item.kind.symbol, color: item.kind.color, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text(item.license).font(.caption).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }
}

private struct LicenseDetail: View {
    let item: ThirdPartyItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    SettingsIcon(symbol: item.kind.symbol, color: item.kind.color, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(item.author).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Chip(text: item.license, color: item.kind.color)
                            Chip(text: item.kind.title, color: .secondary)
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
                    if let url = URL(string: item.url) {
                        Link(destination: url) { label("Source", "arrow.up.right.square") }
                    }
                }
                if let credit = item.credit {
                    Panel(title: String(localized: "Credit", bundle: #bundle)) {
                        Text(credit).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let text = item.fullText {
                    Panel(title: String(localized: "License", bundle: #bundle)) {
                        Text(text)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if item.text == nil {
                    Text("This license doesn't require showing the full text. See the source page.", bundle: #bundle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

private struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}
