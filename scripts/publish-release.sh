#!/bin/zsh
# 把 scripts/release-mac.sh 打好的 dmg 发到 GitHub Releases（Mac 版的「检查更新」读的就是这里的最新正式版）。
# 仓库取 PASEO_RELEASES_REPO（Config/Local.xcconfig 优先，其次 Config/Paseo.xcconfig）。
# 用法：scripts/publish-release.sh <版本号> <发布说明文件>
#   发布说明会原样显示在 App 的更新提示里；中英各一份时用单独一行 --- 隔开，App 只显示 --- 之前的部分。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?用法：scripts/publish-release.sh <版本号> <发布说明文件>}"
NOTES="${2:?缺发布说明文件}"
DMG="build.noindex/dist/Paseo-Native-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "没有 $DMG，先跑 scripts/release-mac.sh $VERSION"; exit 1; }
[[ -f "$NOTES" ]] || { echo "没有发布说明文件 $NOTES"; exit 1; }
REPO=$(sed -nE 's/^PASEO_RELEASES_REPO *= *([^ ]+).*/\1/p' Config/Local.xcconfig 2>/dev/null | tail -1)
[[ -n "$REPO" ]] || REPO=$(sed -nE 's/^PASEO_RELEASES_REPO *= *([^ ]+).*/\1/p' Config/Paseo.xcconfig | tail -1)
[[ -n "$REPO" ]] || { echo "没配置 PASEO_RELEASES_REPO"; exit 1; }

# 再确认一次包里是公证过的、版本号对得上
M=$(hdiutil attach -nobrowse -readonly "$DMG" | tail -1 | awk -F'\t' '{print $NF}')
trap 'hdiutil detach -quiet "$M" 2>/dev/null || true' EXIT
APP="$M/Paseo Native.app"
spctl -a -t exec "$APP" || { echo "✗ 没通过 Gatekeeper（没公证？）"; exit 1; }
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$V" == "$VERSION" ]] || { echo "✗ 包里的版本是 $V，不是 $VERSION"; exit 1; }
hdiutil detach -quiet "$M"; trap - EXIT

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
BODY=$(mktemp); { cat "$NOTES"; echo; echo "SHA-256: \`$SHA\`"; } > "$BODY"
gh release create "v$VERSION" "$DMG" -R "$REPO" --target main --title "Paseo Native $VERSION" --notes-file "$BODY"
rm -f "$BODY"
# 下载回来核对，确认上传完整
GOT=$(curl -sL "https://github.com/$REPO/releases/download/v$VERSION/Paseo-Native-$VERSION.dmg" | shasum -a 256 | cut -d' ' -f1)
[[ "$GOT" == "$SHA" ]] && echo "✓ 已发布 v$VERSION 到 $REPO，下载校验一致" || { echo "✗ 下载回来的校验和不一致：$GOT"; exit 1; }
