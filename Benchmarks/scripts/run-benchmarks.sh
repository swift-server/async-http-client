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

# Runs `swift package benchmark` with the given arguments against `benchmark-server`. The server is started here, as a
# sibling of the benchmark process rather than its child, so none of its work is counted as the client's.
#
# Usage: Benchmarks/scripts/run-benchmarks.sh baseline compare main --filter 'Echo.*'

set -euo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
fatal() {
    printf -- "** ERROR: %s\n" "$*" >&2
    exit 1
}

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

is_running() { kill -0 "$1" 2>/dev/null; } # ignore-unacceptable-language
terminate() { kill -TERM "$1" 2>/dev/null; } # ignore-unacceptable-language

server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]] && is_running "$server_pid"; then
        terminate "$server_pid" || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

port=8443
listening() { (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; }
listening && fatal "port $port is already in use"

# SwiftPM's sandbox blocks the benchmarks' sockets on macOS.
swift build --disable-sandbox -c release --package-path Benchmarks/BenchmarkServer
server="$(swift build --disable-sandbox -c release --package-path Benchmarks/BenchmarkServer --show-bin-path)/benchmark-server"

"$server" &
server_pid=$!
# Traps don't run when this script receives SIGKILL, so a watchdog stops the server once the script is gone.
(
    while is_running "$$"; do sleep 1; done
    terminate "$server_pid"
) </dev/null >/dev/null 2>&1 &

for _ in $(seq 300); do
    listening && break
    is_running "$server_pid" || fatal "benchmark-server exited before it was ready"
    sleep 0.1
done
listening || fatal "benchmark-server wasn't ready after 30 seconds"
log "benchmark-server (pid $server_pid) is listening on 127.0.0.1:$port"

swift package --package-path Benchmarks --disable-sandbox benchmark "$@"
