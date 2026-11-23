# RingoMate

Apple Silicon Mac 用の 3D デスクトップマスコット（Swift 6・Metal 4・macOS 27）。

## ビルドとテスト

Xcode 27 / Swift 6.4。xcode-select が CLT を指しているときは `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

```sh
git submodule update --init                          # C/C++ のライブラリと素材（Bandai・CMU・KayKit）
# つくよみちゃん（assets/tsukuyomi/）は README の手順で各自取る。アセットデータはアプリが R2 から取る（assets/songs はテスト用、CI が取る）
(cd Packages && swift test)                          # テスト
(cd Packages && swift package plugin --allow-writing-to-package-directory swiftlint --strict)  # import のルール
swift run --package-path BuildTools -c release xcodegen   # RingoMate.xcodeproj を作る（コミットしない）
xcodebuild -project RingoMate.xcodeproj -scheme RingoMate -derivedDataPath build build
```

- 署名: Debug は `Config/Local.xcconfig`（コミットしない）の `DEVELOPMENT_TEAM`（Apple Development）。Release は Developer ID（チーム 4RU8L6U52Z。p12 と公証の鍵はリポジトリに置かない）。署名を固定しないとビルドのたびに macOS の許可（画面収録など）が外れる。
- Claude Code のプラグインの `mascot-hook`: `cd Packages && swift build -c release --product mascot-hook` → `claude-plugin/plugins/ringomate/bin/` へ。

## 構成

- `App/`: 起動と組み立てだけ（機能モジュールをクロージャでつなぐ）
- `Packages/Sources/`（SwiftPM の標準の置き方、テストは `Packages/Tests/<名前>Tests`）
  - 機能モジュール: `Overlay`（ウィンドウ・入力）・`Behavior`（行動 AI）・`Agent`（Claude Code のフック）・`AI`（端末内の Foundation Models）・`Voice`（声、swift-irodori-tts）・`Settings`・`Update`（Releases からのアップデート）
  - 感覚: `Listen`（Mac の音・拍・曲の雰囲気）・`Senses`（システムの様子・通知・ウィンドウ・壁紙の物）
  - `Render`（Metal 4）・`CoreBridge`（Engine を毎フレーム回して Render の入力へ）・`MascotCore`（共通の型と小さな道具）・`HookWire`（Agent と mascot-hook の決まり）
  - `Engine`: 読み込み（PMX・VRM・GLB・FBX・BVH・VMD）・評価・IK・物理（Jolt）・曲の聞き分け。アプリのほかのモジュールを import しない
  - `CJolt`: Jolt の C ラッパー。`mascot-hook`: Claude Code のフックと MCP サーバー
- `Packages/Vendor/{Jolt,Ufbx,Meshopt}`: 上流（`Package.swift` がない）を git submodule にして、`Package.swift` だけ自前で包む。上げるときは submodule をタグに合わせてコミット
- `assets/`: 同梱素材。bandai・cmu・kaykit は submodule で、アプリには `assets/<名前>.toml` の `files` だけを入れる（project.yml の Copy listed assets）。ual・ual2・models は直接入れている
- `BuildTools/`: 開発の道具（XcodeGen）。`claude-plugin/`: Claude Code のプラグイン

## ルール

- 依存は上から下の一方向: App → 機能モジュール・感覚 → Render・CoreBridge・MascotCore・HookWire・Engine。機能モジュールどうしは import しない
  （`Package.swift` の依存で止まる）。MascotCore・Engine・Render・HookWire はアプリのほかのモジュールを import しない。
  AppKit・SwiftUI は Overlay・Settings・App だけ、Metal は Render だけ、1 ファイル 400 行まで（`Packages/.swiftlint.yml`、CI で止まる）
- Engine は Debug でも `-O`（最適化なしでは毎フレームが間に合わない）。調整用の値（`MASCOT_*`）は `Flags` で読む（setenv しない）、名前の比較はバイト列で
- Metal 4: MTL4CommandQueue と引数テーブルだけ（Metal 3 系の API は使わない）。GPU が触るリソースは全部レジデンシーセットへ。
  パスをまたぐ読み書きには明示的なバリア。アロケータの reset は MTLSharedEvent で完了を待ってから。出力とテクスチャは乗算済みアルファ
- モデルの読み込みは裏のスレッド、差し替え（`Core.commitLoad` と `Renderer.load`）はメインで続けて

## 規約

- Swift 6 言語モード。1 ファイル 1 責務（400 行まで）
- コメントは最小限（名前で分からない単位・制約だけ）。経緯・検討の内容・内部の情報・個人の情報は書かない
- 意図的な手抜きは `ponytail:` コメントに上限と移行先を 1 行で
- 生成物（xcodeproj・`App/Info.plist`・プラグインの `bin/`）はコミットしない
- 文字列は英語で書く（キー＝英語の文）。UI の文字列は ja の訳をモジュールの `Localizable.xcstrings` に足す（`xcodebuild -exportLocalizations` で取り出し、CI が抜けで止める）。パッケージでは `bundle: #bundle`（`Label`・`Section` などの bundle を取らない部品は Settings の `label`）。AI への指示・状況の説明・Claude 向けの文は英語だけ（カタログに入れない）。ただし性格のプリセットは話す言語の文で渡す（英語で渡すと日本語の文法が崩れる。訳はカタログ）
