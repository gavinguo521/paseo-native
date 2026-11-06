#!/bin/zsh
# Install a separate DEV client; production app and production preference/keychain writes stay untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCTION_APP="/Applications/Paseo Native.app"
DEV_APP="/Applications/Paseo Native DEV.app"
DEV_DERIVED="${PASEO_DEV_DERIVED:-build.noindex/dev}"
DEV_BUILT="$DEV_DERIVED/Build/Products/Debug/Paseo.app"
DEV_STAGED="$DEV_DERIVED/install/Paseo Native DEV.app"
DEV_BASE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PRODUCTION_APP/Contents/Info.plist")
DEV_ID="${DEV_BASE_ID}.dev"

xcodebuild -project Paseo.xcodeproj -scheme Paseo -destination 'platform=macOS' -configuration Debug \
  -derivedDataPath "$DEV_DERIVED" -skipPackagePluginValidation \
  -clonedSourcePackagesDirPath build.noindex/dbg/SourcePackages \
  PASEO_BUNDLE_ID="$DEV_ID" build > "$DEV_DERIVED-build.log" 2>&1
codesign --verify --deep --strict "$DEV_BUILT"
mkdir -p "$DEV_DERIVED/install"
ditto "$DEV_BUILT" "$DEV_STAGED"

python3 - "$DEV_STAGED" "$DEV_BASE_ID" <<'PY'
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
info = app / 'Contents/Info.plist'
with info.open('rb') as f:
    data = plistlib.load(f)
data.update(CFBundleName='Paseo Native DEV', CFBundleDisplayName='Paseo Native DEV',
            PaseoDevBuild=True, PaseoDevSeedBundleID=sys.argv[2], PaseoReleasesRepo='')
# Keep production deep links owned by production.
for entry in data.get('CFBundleURLTypes', []):
    entry['CFBundleURLSchemes'] = ['paseonative-dev']
with info.open('wb') as f:
    plistlib.dump(data, f)
signature = subprocess.run(['codesign', '-d', '--verbose=2', str(app)], capture_output=True, text=True, check=True)
identity = next((line.removeprefix('Authority=') for line in signature.stderr.splitlines()
                 if line.startswith('Authority=')), '-')
subprocess.run(['codesign', '--force', '--sign', identity,
                '--preserve-metadata=entitlements,requirements,flags', str(app)], check=True)
PY
codesign --verify --deep --strict "$DEV_STAGED"
if [[ -e "$DEV_APP" ]]; then
  mv "$DEV_APP" "$DEV_DERIVED/install/Paseo Native DEV-backup-$(date +%Y%m%d%H%M%S).app"
fi
ditto "$DEV_STAGED" "$DEV_APP"
codesign --verify --deep --strict "$DEV_APP"
DEV_LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$DEV_LS" -u "$DEV_BUILT" || true
"$DEV_LS" -u "$DEV_STAGED" || true
"$DEV_LS" -f "$DEV_APP"
echo "DEV installed: $DEV_APP"
