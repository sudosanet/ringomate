#!/bin/bash
# 同梱モデル（つくよみちゃん）と、ASSETS_REPO があればテスト用のアセット（アプリは R2 から取る）を assets/ に取る
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -sfL https://tyc.rei-yumesaki.net/files/3d/tyc-3d-a.zip -o "$tmp/tyc.zip"
echo "abda963d1e9e35be423e7d83758b7c4320af43c9c4af5396c70d8206b8f4e4ad  $tmp/tyc.zip" | shasum -a 256 -c
bsdtar -xf "$tmp/tyc.zip" -C "$tmp" --options zip:hdrcharset=CP932
d="$tmp/つくよみちゃん公式3Dモデル タイプA"
cp "$d/01 通常版（VRM）/【輪郭線なし】つくよみちゃん公式3Dモデル タイプA（通常版）.vrm" assets/tsukuyomi/Tsukuyomi.vrm
cp "$d/ReadMe.txt" "$d/利用規約.txt" assets/tsukuyomi/

if [[ -n "${ASSETS_REPO:-}" ]]; then
  gh release download assets -R "$ASSETS_REPO" -p songs.tar.gz -O - | tar -xz -C assets
fi
