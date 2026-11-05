# 发版脚本共用：从 Config/Local.xcconfig 读签名团队和 bundle ID（source 进来用）。
LOCAL_XCCONFIG=Config/Local.xcconfig
[[ -f "$LOCAL_XCCONFIG" ]] || { echo "缺 $LOCAL_XCCONFIG：复制 Config/Local.xcconfig.example 并填好团队和 bundle ID"; exit 1; }
TEAM=$(sed -nE 's/^DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' "$LOCAL_XCCONFIG")
BUNDLE_ID=$(sed -nE 's/^PASEO_BUNDLE_ID *= *([^ ]+).*/\1/p' "$LOCAL_XCCONFIG")
[[ -n "$TEAM" && -n "$BUNDLE_ID" ]] || { echo "$LOCAL_XCCONFIG 里要有 DEVELOPMENT_TEAM 和 PASEO_BUNDLE_ID"; exit 1; }
