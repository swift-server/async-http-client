#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the AsyncHTTPClient open source project
##
## Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##
set -eu

# Validate that we're running on Linux
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Error: This script must be run on Linux. Current OS: $(uname -s)" >&2
    exit 1
fi

echo "Running on Linux - proceeding with linkage test..."

# Build the linkage test package
echo "Building linkage test package..."
swift build --package-path Tests/LinkageTest

# Check the architecture and build path
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    BUILD_PATH="Tests/LinkageTest/.build/x86_64-unknown-linux-gnu/debug/linkageTest"
elif [[ "$ARCH" == "aarch64" ]]; then
    BUILD_PATH="Tests/LinkageTest/.build/aarch64-unknown-linux-gnu/debug/linkageTest"
else
    echo "Error: Unsupported architecture: $ARCH" >&2
    exit 1
fi

# Verify the binary exists
if [[ ! -f "$BUILD_PATH" ]]; then
    echo "Error: Built binary not found at $BUILD_PATH" >&2
    exit 1
fi

echo "Checking linkage for binary: $BUILD_PATH"

# Run ldd and check if libFoundation.so is linked
LDD_OUTPUT=$(ldd "$BUILD_PATH")
echo "LDD output:"
echo "$LDD_OUTPUT"

if echo "$LDD_OUTPUT" | grep -q "libFoundation.so"; then
    echo "Error: Binary is linked against libFoundation.so - this indicates incorrect linkage. Ensure the full Foundation is not linked on Linux when default traits are disabled." >&2
    exit 1
else
    echo "Success: Binary is not linked against libFoundation.so - linkage test passed."
fi