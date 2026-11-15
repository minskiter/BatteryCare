#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/work/tests"
(cd "$ROOT/Hardware" && go test -mod=vendor -race -v ./...)
for NAME in ModelTests IconTests PlacementTests IntegratedTests LocalizationTests; do
  xcrun swiftc -parse-as-library -swift-version 5 -D BATTERYBAR_TESTING -target "$(uname -m)-apple-macosx13.0" \
    "$ROOT/Sources/Localization.swift" "$ROOT/Sources/BatteryCare.swift" "$ROOT/Sources/IntegratedEngine.swift" "$ROOT/tests/$NAME.swift" \
    -o "$ROOT/work/tests/$NAME" -framework AppKit -framework SwiftUI -framework ServiceManagement -framework IOKit
  "$ROOT/work/tests/$NAME"
done
