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
metrics=(
    --metric mallocCountTotal
    --metric readSyscalls
    --metric writeSyscalls
)
arguments=(
    --format metricP90AbsoluteThresholds
    --path "$thresholds"
    "${metrics[@]}"
    --no-progress
)

annotate() {
    local level="$1" title="$2" message="$3" cr=$'\r' lf=$'\n'
    [[ "${GITHUB_ACTIONS:-}" == "true" ]] || return 0
    message="${message//\%/%25}"
    message="${message//$cr/%0D}"
    message="${message//$lf/%0A}"
    echo "::$level title=$title::$message"
}

# Checking and updating read the stored baseline, so they don't need the server.
benchmark() { swift package --package-path Benchmarks --disable-sandbox benchmark "$@"; }

Benchmarks/scripts/run-benchmarks.sh baseline update ci "${metrics[@]}" --no-progress

status=0
benchmark thresholds check ci "${arguments[@]}" || status=$?

benchmark thresholds update ci "${arguments[@]}"
git add --intent-to-add "$thresholds"
diff="$(git diff HEAD -- "$thresholds")"
echo "=== BEGIN DIFF ==="
echo "$diff"

title="Benchmark thresholds ($SWIFT_VERSION)"
if [[ "$status" -ne 0 ]]; then
    annotate error "$title" "Outside the thresholds. Apply this diff with git apply:"$'\n'"$diff"
elif [[ -n "$diff" ]]; then
    annotate notice "$title" "Within the thresholds. Measured values:"$'\n'"$diff"
else
    annotate notice "$title" "Measured values equal the thresholds."
fi
exit "$status"
