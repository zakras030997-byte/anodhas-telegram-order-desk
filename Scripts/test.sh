#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK_PATH="${ORDER_DESK_SDK:-$(xcrun --show-sdk-path)}"
mkdir -p .build/module-cache Verification
xcrun swiftc -O -parse-as-library -sdk "$SDK_PATH" -module-cache-path .build/module-cache Sources/Orders.swift Sources/Telegram.swift Tests/Suite.swift -o .build/OrderTests
.build/OrderTests > Verification/tests.json
cat Verification/tests.json
