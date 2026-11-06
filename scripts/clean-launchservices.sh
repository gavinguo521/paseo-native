#!/bin/zsh
# 撤销这个 App 所有多余副本的 LaunchServices 登记，只留 /Applications 里装好的那份。
# xcodebuild 和挂载的 dmg 都会登记副本。同一个 Bundle ID 有多份时，通知中心可能用了别的那份的图标（删掉后通知就没图标），
# paseonative:// 链接也可能被交给某份调试版（会把它启动起来、开出空窗口）。
# 按 Bundle ID 从登记表查，覆盖 DerivedData、临时目录和 dmg 卷，也包括 Watch、灵动岛和测试用的副本。
# install-mac.sh、release-mac.sh 会调用；通知又没图标时也可以单独运行，运行后下一条通知生效。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

KEEP="/Applications/Paseo Native.app"
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

stale=("${(@f)$("$LS" -dump | BUNDLE_ID="$BUNDLE_ID" KEEP="$KEEP" awk '
  /^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
  /^identifier:/ {
    id = ENVIRON["BUNDLE_ID"]
    if (($2 == id || index($2, id ".") == 1) && index(path, ENVIRON["KEEP"]) != 1) print path
  }' | sort -u)}")
count=0
for p in "${stale[@]}"; do
  [[ -n "$p" ]] || continue
  "$LS" -u "$p" 2>/dev/null || true
  count=$((count + 1))
done
[[ ! -e "$KEEP" ]] || "$LS" -f "$KEEP"
echo "已撤销 $count 份多余登记"
