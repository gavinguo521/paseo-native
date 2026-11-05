#!/bin/zsh
# 发 iPhone / iPad 版到 TestFlight：用 Config/Local.xcconfig 里的团队做 App Store 分发签名，上传到 App Store Connect。
# 签名和上传都走 Xcode 里登录的账号（云端证书），不用证书文件和密码。
# 前提：App Store Connect 里已经建好 Bundle ID 为 Config/Local.xcconfig 里 PASEO_BUNDLE_ID 的 App。
# 用法：
#   scripts/release-ios.sh --check [版本号]   只归档、导出、检查，不上传
#   scripts/release-ios.sh [版本号]           检查通过后上传
#   不写版本号就用 project.yml 里的 MARKETING_VERSION（和 Mac 版共用，写了会改它）。
#   build 号 = 提交数；App Store Connect 不收重复的 build 号，同一个提交传第二次要先提交，或 BUILD_NUMBER=<更大的数>。
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && { CHECK_ONLY=1; shift; }
VERSION="${1:-$(sed -nE 's/^    MARKETING_VERSION: "(.*)"/\1/p' project.yml)}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "版本号要写成 x.y.z：$VERSION"; exit 1; }
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
source scripts/signing.sh
DIST=build.noindex/dist-ios
ARCHIVE="$DIST/Paseo.xcarchive"

[[ -z "$(git status --porcelain)" ]] || echo "⚠︎ 有没提交的改动，会一起打进包里"

sed -i '' -E "s/^(    MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || { echo "没改成 project.yml 里的版本号"; exit 1; }
xcodegen generate >/dev/null

rm -rf "$DIST" && mkdir -p "$DIST"
echo "▸ 归档 $VERSION ($BUILD)"
xcodebuild -project Paseo.xcodeproj -scheme Paseo -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath build.noindex/ios-rel -archivePath "$ARCHIVE" -allowProvisioningUpdates -skipPackagePluginValidation \
  CURRENT_PROJECT_VERSION="$BUILD" archive 2>&1 | grep -E "error:|\*\* ARCHIVE" | tail -3
[[ -d "$ARCHIVE" ]] || exit 1

# destination: export 先在本地导出一份检查，upload 才真的传。
export_options() {
  cat > "$DIST/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
<key>destination</key><string>$1</string>
<key>uploadSymbols</key><true/>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
}

echo "▸ 导出（App Store 分发签名）"
export_options export
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$DIST/export.plist" \
  -exportPath "$DIST/export" -allowProvisioningUpdates 2>&1 | grep -E "error:|\*\* EXPORT" | tail -3
IPA=("$DIST"/export/*.ipa(N))
(( ${#IPA} )) || { echo "没导出 ipa"; exit 1; }
ditto -x -k "$IPA[1]" "$DIST/ipa"
APP="$DIST/ipa/Payload/Paseo.app"
WIDGET="$APP/PlugIns/PaseoWidgets.appex"

echo "▸ 上传前检查"
fail=0
ok() { echo "  ✓ $*" }
bad() { echo "  ✗ $*"; fail=1 }
info() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist" 2>/dev/null || true }
ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true }

# 管道里不用 grep -q：pipefail 下 grep 提前退出会让前一个命令收到 SIGPIPE、整条算失败。先取输出再查。
# 版本号：主 App 和 Widget 扩展必须一致，否则上传被拒。
for b in "$APP" "$WIDGET"; do
  [[ "$(info "$b" CFBundleShortVersionString)" == "$VERSION" && "$(info "$b" CFBundleVersion)" == "$BUILD" ]] \
    && ok "${b:t} 版本 $VERSION ($BUILD)" || bad "${b:t} 版本是 $(info "$b" CFBundleShortVersionString) ($(info "$b" CFBundleVersion))，应为 $VERSION ($BUILD)"
done

# 分发签名：App Store 描述文件不带设备列表；推送要 production；不能带调试权限。
grep -q "Authority=Apple Distribution" <<< "$(codesign -dvv "$APP" 2>&1)" && ok "Apple Distribution 签名" || bad "不是 Apple Distribution 签名"
security cms -D -i "$APP/embedded.mobileprovision" > "$DIST/profile.plist" 2>/dev/null
/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$DIST/profile.plist" >/dev/null 2>&1 \
  && bad "描述文件带设备列表（是 Ad Hoc / 开发用的，不是 App Store 的）" || ok "App Store 描述文件"
[[ "$(grep -A1 "aps-environment" <<< "$(ents "$APP")")" == *production* ]] && ok "推送环境 production" || bad "aps-environment 不是 production"
for b in "$APP" "$WIDGET"; do
  [[ "$(grep -A1 "get-task-allow" <<< "$(ents "$b")")" == *"<true/>"* ]] && bad "${b:t} 带 get-task-allow（调试权限）" || ok "${b:t} 没有调试权限"
done

# Info.plist：用到相机、相册必须写用途说明；iPad 支持分屏要四个方向 + 启动屏。
for k in NSCameraUsageDescription NSPhotoLibraryUsageDescription; do
  [[ -n "$(info "$APP" $k)" ]] && ok "$k：$(info "$APP" $k)" || bad "缺 $k"
done
/usr/libexec/PlistBuddy -c "Print :UILaunchScreen" "$APP/Info.plist" >/dev/null 2>&1 && ok "有启动屏" || bad "缺 UILaunchScreen"
[[ $(grep -c Orientation <<< "$(info "$APP" "UISupportedInterfaceOrientations~ipad")") -eq 4 ]] \
  && ok "iPad 四个方向" || bad "iPad 要支持四个方向（分屏）"
case "$(info "$APP" ITSAppUsesNonExemptEncryption)" in
  false) ok "出口合规：ITSAppUsesNonExemptEncryption = false（App 里有 Noise 加密通道，这个申报要公司确认）" ;;
  true) ok "出口合规：ITSAppUsesNonExemptEncryption = true" ;;
  *) bad "缺 ITSAppUsesNonExemptEncryption（每次上传都会在网页上问）" ;;
esac

# 图标：iOS 1024 图不能有透明通道。
ICON=App/Resources/Assets.xcassets/AppIcon.appiconset/icon-ios.png
[[ "$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$ICON" | awk '/pixel|hasAlpha/ {printf "%s ", $2}')" == "1024 1024 no " ]] \
  && ok "图标 1024×1024、无透明" || bad "$ICON 要 1024×1024 且不能有透明通道"
[[ -n "$(info "$APP" CFBundleIcons)" ]] && ok "图标已编进 App" || bad "Info.plist 没有 CFBundleIcons"

# 隐私清单。
plutil -lint -s "$APP/PrivacyInfo.xcprivacy" 2>/dev/null && ok "隐私清单" || bad "App 里没有有效的 PrivacyInfo.xcprivacy"

# 调试代码（#if DEBUG）不能编进去。
if grep -qE "PASEO_SCROLL_BENCH|PASEO_OPEN|PASEO_PAIRING" <<< "$(strings "$APP/Paseo")"; then bad "二进制里有 DEBUG 调试参数"; else ok "没有 DEBUG 调试代码"; fi

echo "  ipa $(du -h "$IPA[1]" | cut -f1)，最低系统 iOS $(info "$APP" MinimumOSVersion)"
(( fail )) && { echo "✗ 检查没通过，没有上传"; exit 1 }
(( CHECK_ONLY )) && { echo "✓ 检查通过（--check，没有上传）"; exit 0 }

echo "▸ 上传到 App Store Connect"
export_options upload
out=$(xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$DIST/upload.plist" \
  -exportPath "$DIST/upload" -allowProvisioningUpdates 2>&1) || true
if ! grep -q "EXPORT SUCCEEDED" <<< "$out"; then
  grep -iE "error|fail" <<< "$out" | tail -10
  grep -qiE "application record|No suitable application" <<< "$out" && echo "→ App Store Connect 里还没有 $BUNDLE_ID 这个 App，先建好再传"
  grep -qiE "bundle version|CFBundleVersion.*(already|previous)" <<< "$out" && echo "→ build 号 $BUILD 已经传过，提交后再传，或 BUILD_NUMBER=<更大的数>"
  exit 1
fi
rm -rf "$DIST/export" "$DIST/ipa" "$DIST/upload"
echo "✓ 已上传 $VERSION ($BUILD)。App Store Connect 处理完（一般 5–30 分钟）会在 TestFlight 里出现；"
echo "  外部测试组要手动加这个构建，每个新版本第一次加时要过一次 Beta 审核。"
