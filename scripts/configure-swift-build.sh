#!/usr/bin/env bash
# Source from package scripts after ROOT_DIR is set.

if [[ -z "${SDKROOT:-}" ]] && [[ "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" ]]; then
  # The current Command Line Tools install pairs Swift 6.3.3 with a 26.5 SDK
  # built by Swift 6.3.2. The installed 15.4 SDK is compatible with this app's
  # macOS 14 deployment target and builds successfully with that compiler.
  FALLBACK_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  if [[ -d "$FALLBACK_SDK" ]]; then
    export SDKROOT="$FALLBACK_SDK"
  fi
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
