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

# Checks the benchmarks' count metrics against Benchmarks/Thresholds/$SWIFT_VERSION. If they changed, it rewrites the
# thresholds and prints the diff to commit. Timing metrics aren't checked: they're too noisy on shared CI machines.
#
# Usage: SWIFT_VERSION=6.4 Benchmarks/scripts/check-thresholds.sh

set -euo pipefail

: "${SWIFT_VERSION:?SWIFT_VERSION must name the thresholds directory, for example 6.4}"

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

thresholds="Benchmarks/Thresholds/$SWIFT_VERSION"
arguments=(
    --format metricP90AbsoluteThresholds
    --path "$thresholds"
    --metric mallocCountTotal
    --metric readSyscalls
    --metric writeSyscalls
    --no-progress
)

if Benchmarks/scripts/run-benchmarks.sh thresholds check "${arguments[@]}"; then
    exit 0
fi

Benchmarks/scripts/run-benchmarks.sh thresholds update "${arguments[@]}"
echo "=== BEGIN DIFF ==="
git add --intent-to-add "$thresholds"
git diff HEAD -- "$thresholds"
exit 1
