#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWIFT="$(xcrun --find swift)"
TOOLCHAIN_USR="$(cd "$(dirname "$SWIFT")/.." && pwd)"
PLUGIN="$TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
# CLT 6.4 includes Swift Testing but swiftbuild omits its macro-plugin search path.
# Load that installed plugin explicitly; no downloads or system changes.
if [[ ! -f "$PLUGIN" ]]; then echo "Swift Testing plugin not found: $PLUGIN" >&2; exit 1; fi
exec "$SWIFT" test --build-system swiftbuild --disable-xctest --enable-swift-testing \
    -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN"
