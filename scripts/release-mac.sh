#!/bin/zsh
# 打给同事用的 Mac 安装包：用 Config/Local.xcconfig 里团队的 Developer ID 签名、苹果公证，输出 dmg。
# 签名和公证都走 Xcode 里登录的账号（云端证书），不用证书文件和密码。
# 用法：scripts/release-mac.sh <版本号>，如 scripts/release-mac.sh 1.1.0
#   版本号写进 project.yml 的 MARKETING_VERSION；build 号 = 提交数。
#   产物：build.noindex/dist/Paseo-Native-<版本号>.dmg，并复制到桌面（里面是「Paseo Native.app」，拖进「应用程序」，
#   不会覆盖官方的 Paseo.app）。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法：scripts/release-mac.sh <版本号>，如 1.1.0}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "版本号要写成 x.y.z：$VERSION"; exit 1; }
DIST=build.noindex/dist
ARCHIVE="$DIST/Paseo.xcarchive"
DMG="$DIST/Paseo-Native-$VERSION.dmg"
source scripts/signing.sh
[[ "${SKIP_I18N_CHECK:-}" == "1" ]] || scripts/check-i18n.sh
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

sed -i '' -E "s/^(    MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || { echo "没改成 project.yml 里的版本号"; exit 1; }
xcodegen generate >/dev/null

rm -rf "$DIST" && mkdir -p "$DIST"
echo "▸ 归档 $VERSION ($(git rev-list --count HEAD))"
xcodebuild -project Paseo.xcodeproj -scheme Paseo -destination 'generic/platform=macOS' -configuration Release \
  -derivedDataPath build.noindex/rel -archivePath "$ARCHIVE" -allowProvisioningUpdates -skipPackagePluginValidation \
  CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" archive 2>&1 | grep -E "error:|\*\* ARCHIVE" | tail -3
[[ -d "$ARCHIVE" ]] || exit 1

echo "▸ 上传公证"
cat > "$DIST/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
<key>destination</key><string>upload</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$DIST/ExportOptions.plist" \
  -exportPath "$DIST/upload" -allowProvisioningUpdates 2>&1 | grep -E "error:|\*\* EXPORT" | tail -3

echo "▸ 等公证结果（一般 1–5 分钟）"
for i in {1..60}; do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$DIST/notarized" 2>&1 | grep -q "EXPORT SUCCEEDED"; then break; fi
  (( i == 60 )) && { echo "30 分钟还没公证完，稍后再跑：xcodebuild -exportNotarizedApp -archivePath $ARCHIVE -exportPath $DIST/notarized"; exit 1; }
  sleep 30
done
xcrun stapler validate "$DIST/notarized/Paseo.app" >/dev/null
spctl -a -t exec "$DIST/notarized/Paseo.app"

echo "▸ 打包 dmg"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
ditto "$DIST/notarized/Paseo.app" "$STAGE/Paseo Native.app"
ln -s /Applications "$STAGE/应用程序"
hdiutil create -quiet -volname "Paseo Native $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"

# 中间产物都删掉并注销：同一个 Bundle ID 留着多份，启动台会多出图标、通知图标也可能丢。
# 归档里的 Submissions/ 也有一份（公证时上传的那份）。
for a in "$PWD/$DIST"/**/*.app(N/); do
  [[ "$a" == *.app/*.app ]] || "$LS" -u "$a" 2>/dev/null || true
done
rm -rf "$STAGE" "$DIST/notarized" "$DIST/upload"
cp "$DMG" "$HOME/Desktop/"
echo "✓ $DMG（$(du -h "$DMG" | cut -f1)），已复制到桌面"
