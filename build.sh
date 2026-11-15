#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/BatteryCare.app"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CGO_CFLAGS="${CGO_CFLAGS:-} -mmacosx-version-min=13.0"
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -mmacosx-version-min=13.0"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
# The final app has no Python dependency and never starts a Python/HTTP server.
xcrun swiftc -parse-as-library -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  "$ROOT/Sources/BatteryCare.swift" "$ROOT/Sources/IntegratedEngine.swift" -o "$APP/Contents/MacOS/BatteryCare" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework IOKit
(cd "$ROOT/Hardware" && CGO_ENABLED=1 go build -mod=vendor -trimpath -o "$APP/Contents/Helpers/BatteryHardware" .)
(cd "$ROOT/Dependencies/iSMC" && CGO_ENABLED=1 go build -mod=vendor -trimpath -o "$APP/Contents/Helpers/iSMC" .)
install -m 644 "$ROOT/Hardware/LICENSE" "$APP/Contents/Resources/Licenses/Hardware-GPL-2.0.txt"
install -m 644 "$ROOT/Dependencies/iSMC/LICENSE" "$APP/Contents/Resources/Licenses/iSMC-GPL-3.0.txt"
install -m 644 "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/BatteryCare-GPL-3.0.txt"
install -m 644 "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
# Include complete corresponding source for the App and both GPL executables.
tar -czf "$APP/Contents/Resources/CorrespondingSource.tar.gz" -C "$ROOT" \
  Sources Hardware Dependencies/iSMC tests assets docs build.sh test.sh README.md LICENSE THIRD_PARTY_NOTICES.md CONTRIBUTING.md
/usr/bin/python3 - "$APP/Contents/Resources/battery.py" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
if p.is_file(): p.unlink()
PY
/usr/bin/python3 - "$APP" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = dict(CFBundleName="BatteryCare", CFBundleDisplayName="BatteryCare", CFBundleIdentifier="com.local.batterybar",
            CFBundleExecutable="BatteryCare", CFBundlePackageType="APPL", CFBundleShortVersionString="2.0.0",
            CFBundleVersion="5", LSMinimumSystemVersion="13.0", LSUIElement=True, NSHighResolutionCapable=True,
            CFBundleIconFile="AppIcon")
with open(app/"Contents/Info.plist", "wb") as f: plistlib.dump(info, f)
PY
xcrun swift "$ROOT/Sources/Icon.swift" "$APP/Contents/Resources"
codesign --force --sign - "$APP/Contents/Helpers/BatteryHardware"
codesign --force --sign - "$APP/Contents/Helpers/iSMC"
codesign --force --sign - "$APP"
echo "Built self-contained App: $APP"
