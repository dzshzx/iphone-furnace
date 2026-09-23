#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang++ -std=c++20 -fobjc-arc -I Sources/Native \
  -framework Foundation -framework IOSurface \
  Sources/Native/PrivateANE.mm scripts/probe_private_ane.mm -o build/probe-private-ane
build/probe-private-ane >build/private-ane-model.log 2>&1 || {
  cat build/private-ane-model.log
  exit 1
}
cat build/private-ane-model.log
