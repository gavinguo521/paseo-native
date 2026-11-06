#!/bin/zsh
# 检查界面文案是否都有英文：先导出（会把代码里新增的文案同步进 String Catalog），再列出缺英文的条目。
# 用法：scripts/check-i18n.sh；有缺失时退出码 1。release-mac.sh 发版前会调用（SKIP_I18N_CHECK=1 可跳过）。
# 补翻译：直接编辑各 Localizable.xcstrings（Xcode 里打开就是表格），或按 docs/i18n.md 的流程批量处理。
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d Paseo.xcodeproj ]] || xcodegen generate >/dev/null
OUT=$(mktemp -d)
xcodebuild -exportLocalizations -project Paseo.xcodeproj -localizationPath "$OUT" -exportLanguage en -skipPackagePluginValidation >/dev/null 2>&1 \
  || { echo "导出文案失败，先确认能正常编译"; exit 1; }
python3 - <<'PY'
import json, re, sys
cats = ['App/Resources/Localizable.xcstrings', 'Widgets/Localizable.xcstrings', 'PaseoKit/Sources/PaseoKit/Resources/Localizable.xcstrings',
        'App/Resources/InfoPlist.xcstrings', 'Widgets/InfoPlist.xcstrings',
        'Watch/Resources/Localizable.xcstrings', 'Watch/Resources/InfoPlist.xcstrings']
miss = []
for c in cats:
    try: d = json.load(open(c))['strings']
    except FileNotFoundError: continue
    for k, v in d.items():
        if v.get('shouldTranslate') is False or v.get('extractionState') == 'stale': continue
        src = v.get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value', k)
        if re.search(r'[一-鿿]', src) and 'en' not in v.get('localizations', {}): miss.append(f'{c}: {k}')
if miss:
    print(f'✗ {len(miss)} 条文案缺英文：'); print('\n'.join('  ' + m for m in miss[:50])); sys.exit(1)
print('✓ 界面文案都有英文')
PY
