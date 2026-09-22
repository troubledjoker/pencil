#!/usr/bin/env bash
# Compiles scripts/make-icon.swift with the shared artwork and renders the icon into Resources/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build Resources
swiftc -parse-as-library -O scripts/make-icon.swift Sources/PencilCore/IconArt.swift -o .build/make-icon
.build/make-icon Resources
