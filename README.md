# RingoMate

Apple Silicon の Mac のデスクトップに 3D のキャラクターを住まわせるマスコットアプリ。PMX・PMD・VRM・GLB・FBX のモデルを読み込み、
歩く・ウィンドウによじ登って座る・うとうとする・つまんで投げられる・撫でると喜ぶ。流れている曲に合わせて踊り、Claude Code の
作業状況（考え中・実行中・承認待ち・完了）にも反応する。AI は端末の中だけで動き、画面や音を外へ送らない。

## インストール

[Releases](../../releases) の dmg を開き、`RingoMate.app` を `Applications` へ入れる。

初めて起動すると、踊りなどのアセット（約 300MB）を落とす。落としている間は、メニューバーのメニューに進み具合が出る。そのあとは 1 日ごとに、変わった分だけを落とす。

新しい版が出ると、メニューバーのメニューに「アップデートして再起動」が出る。

### Claude Code のプラグイン

同じ Releases の `ringomate-claude-plugin-<版>.zip` を展開し、Claude Code にマーケットプレイスとして足して入れる。

```sh
claude plugin marketplace add ~/Downloads/ringomate-claude-plugin
claude plugin install ringomate@ringomate
```

## 必要なもの（ビルドする場合）

macOS 27 / Xcode 27.2（Swift 6.4）。ほかの道具は SwiftPM が取ってくる。

## ビルド

```sh
git clone --recursive https://github.com/sudosanet/ringomate.git       # 素材（Bandai・CMU・KayKit）と C/C++ のライブラリは submodule（合わせて約 4GB）
swift run --package-path BuildTools -c release xcodegen
xcodebuild -project RingoMate.xcodeproj -scheme RingoMate -derivedDataPath build build
```

同梱のキャラクター（つくよみちゃん）は規約上リポジトリに入れていないので、`scripts/fetch-assets.sh` で[配布元](https://tyc.rei-yumesaki.net/material/avatar/3d-a/)の ZIP から
`assets/tsukuyomi/` に取る（手で置くなら `01 通常版（VRM）/【輪郭線なし】…（通常版）.vrm` を `Tsukuyomi.vrm` とし、`ReadMe.txt`・`利用規約.txt` も同じフォルダへ）。

Debug は `Config/Local.xcconfig` に `DEVELOPMENT_TEAM = <チーム ID>` を書く（コミットしない）。Apple Development の証明書が同じなら、手元の再ビルドで画面収録などの許可は残る。
Release はキーチェーンにある自己署名「RingoMate」で署名する。証明書のファイルはリポジトリに入れない。
テストは `cd Packages && swift test`。

GitHub の Release も同じ自己署名を使う。リポジトリの Actions secrets に次を入れる。

- `RINGOMATE_P12`: 証明書の p12 を base64 した文字列
- `RINGOMATE_P12_PASSWORD`: その p12 のパスワード

## 使い方

- メニューバーのアイコンから: キャラクターを隠す、話しかける（Talk…）、設定（⌘,、モデルの切り替え・大きさ・見た目など）。
- キャラクター: 頭をクリックすると笑って跳ねる、手は振り返す、ドラッグでつまむ、撫でると喜ぶ。
- Claude Code: プラグイン（上のインストール）を入れると、フックで状態が届き、MCP（`say`・`perform`・`express`・`get_state`）と
  `/mascot` で演出を頼める。ソースから作るときは `cd Packages && swift build -c release --product mascot-hook` で作ったものを
  `claude-plugin/plugins/ringomate/bin/` に置き、`claude-plugin/` をマーケットプレイスとして足す。
- ショートカット・Siri: 「RingoMate に話しかける」「RingoMate に仕草をさせる」「RingoMate を隠す」。
- 曲に合わせて踊る: Mac で流している曲を聞き分けて、その曲の振り付けで踊る。

## 曲を追加する

`~/Library/Application Support/ringomate/songs/<id>/` にフォルダを置くと、アプリが見つけて読む（再起動はいらない）。

```
<id>/
  song.toml          # 下の書き方
  dance.vmd          # 踊り（VMD・BVH・GLB、gzip も）
  audio/original.m4a # 曲の音源（wav・mp3・m4a・flac など）。版がいくつかあれば全部
```

```toml
schema = 1
id = "my-song"
title = "曲名"
artist = "アーティスト"

[dance]
file = "dance.vmd"
offset = 0.0           # 踊りの 0 秒が、最初の版の音源の何秒か（MMD の踊りは多くが 0）

[[version]]            # 最初が基準の版
name = "original"
audio = "audio/original.m4a"
```

初めて読むときに、アプリが音源から解析を作る（1 曲数秒）。音源はフォルダにあるものだけを読み、ほかへ写したり送ったりしない。

## 構成

```
App/                アプリの起動と組み立て
Packages/Sources/   Swift のモジュール（Overlay・Behavior・Agent・AI・Voice・Settings・Listen・Senses・Render・CoreBridge・MascotCore・HookWire・Engine・CJolt・mascot-hook）
Packages/Tests/     テスト
Packages/Vendor/    C/C++ のライブラリ（Jolt Physics・ufbx・meshoptimizer、git submodule）
assets/             同梱素材（submodule とマニフェスト）
BuildTools/         開発の道具（XcodeGen）
claude-plugin/      Claude Code のプラグイン（フック・MCP・スキル）
```
## クレジット

- 「つくよみちゃん」© Rei Yumesaki。本ソフトウェアでは、フリー素材キャラクター「つくよみちゃん」を使用しています。収録している 3D モデルの利用規約は
  [つくよみちゃん公式3Dモデル タイプA](https://tyc.rei-yumesaki.net/material/avatar/3d-a/)（VRM 制作: 夢前黎）の規約に準じます。
  つくよみちゃんを使ったコンテンツを公開するときは[つくよみちゃんキャラクターライセンス](https://tyc.rei-yumesaki.net/about/terms/)に従ってください。
- [Bandai Namco Research Motion Dataset](https://github.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset) © Bandai Namco Research Inc.（CC BY-NC 4.0、アプリ用にリターゲットして使用）
- [CMU Graphics Lab Motion Capture Database](http://mocap.cs.cmu.edu)（NSF EIA-0196217）
- [Universal Animation Library 1・2](https://quaternius.itch.io/universal-animation-library)（Quaternius、CC0）・[KayKit Furniture Bits](https://github.com/KayKit-Game-Assets/KayKit-Furniture-Bits-1.0)（Kay Lousberg、CC0）
- [Beat This!](https://github.com/CPJKU/beat_this)（JKU Linz、MIT）・[LAION-CLAP](https://github.com/LAION-AI/CLAP)（LAION、Apache-2.0）

ほかの素材・ライブラリと全文はアプリの設定の「ライセンス」にある。

## プライバシー

[PRIVACY.md](PRIVACY.md)。設定の About からも開ける。

## ライセンス

ソースコードは [Apache License 2.0](LICENSE)。アプリに入っているキャラクター・モーション・モデル・ライブラリは、それぞれの作者の
ライセンスに従う（アプリの設定の「ライセンス」、全文は `Packages/Sources/Settings/Licenses/`）。Bandai Namco Research Motion Dataset が CC BY-NC 4.0 なので、
素材入りのアプリは非営利でだけ配布できる。読み込んだモデルの権利は各作者にあり、アプリはモデルを取ってきたり共有したりしない。