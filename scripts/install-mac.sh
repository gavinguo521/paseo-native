#!/bin/zsh
# 编译 Release 版并装到 ~/Applications/Paseo Native.app（/Applications/Paseo.app 是官方 App，不要覆盖）。
# 旧版先从 LaunchServices 取消登记再直接删除：放进废纸篓的话，启动台和程序坞会把它当成又一个 Paseo。
# 编译目录用 build.noindex：带 .noindex 后缀 Spotlight 不收录，编译出的 Paseo.app 不会出现在启动台里。
# 用法：scripts/install-mac.sh [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$HOME/Applications/Paseo Native.app"
BUILT="build.noindex/rel/Build/Products/Release/Paseo.app"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ "${1:-}" != "--no-build" ]]; then
  [[ -d Paseo.xcodeproj ]] || xcodegen generate
  # Build number = commit count: macOS caches app icons (Dock, Stage Manager) per bundle version,
  # so an unchanged "1" keeps showing an old icon after the icon changes.
  xcodebuild -project Paseo.xcodeproj -scheme Paseo -destination 'platform=macOS' -configuration Release \
    -derivedDataPath build.noindex/rel -allowProvisioningUpdates -skipPackagePluginValidation \
    CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" build 2>&1 | grep -E "error:|\*\* BUILD" | tail -3
fi
codesign --verify --deep --strict "$BUILT"

# 退出正在运行的版本（草稿按会话保存，不会丢）。
osascript -e 'quit app "Paseo Native"' 2>/dev/null || true
sleep 2
pkill -f "Paseo Native.app/Contents/MacOS" 2>/dev/null || true

mkdir -p "$HOME/Applications"
if [[ -e "$APP" ]]; then
  "$LS" -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
fi
# 以前的版本放进废纸篓的旧版。
for f in "$HOME"/.Trash/Paseo\ Native-*.app(N); do "$LS" -u "$f" 2>/dev/null || true; rm -rf "$f"; done

ditto "$BUILT" "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"
"$LS" -f "$APP"
# xcodebuild 会登记编译产物，同一个 Bundle ID 有多份时，通知中心可能用了别的那份的图标（删掉后通知就没图标），
# paseonative:// 链接也可能被交给某份调试版（会把它启动起来、开出空窗口）。仓库里所有编译副本都撤销登记，只留装好的这份。
for f in "$PWD"/build.noindex/*/Build/Products/*/Paseo.app(N) "$PWD"/build/*/Build/Products/*/Paseo.app(N); do "$LS" -u "$f" 2>/dev/null || true; done
open "$APP"
echo "已安装并打开：$APP"
