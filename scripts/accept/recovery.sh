#!/bin/bash
# Real production Swift API against an isolated backend and local fault fixture.
set -euo pipefail
source "$(dirname "$0")/_common"
accept_compile scripts/accept/recovery/Recovery.swift
accept_start_backend
python3 scripts/accept/recovery/fixture.py "$ACCEPT_TMP/fault-port" >"$ACCEPT_TMP/fault.log" 2>&1 &
fault_pid=$!
ACCEPT_PIDS+=("$fault_pid")
for _ in $(seq 1 50); do
  kill -0 "$fault_pid" 2>/dev/null || break
  [ ! -s "$ACCEPT_TMP/fault-port" ] || break
  sleep 0.1
done
[ -s "$ACCEPT_TMP/fault-port" ] || { echo 'FAIL: local fault fixture did not start' >&2; exit 1; }
export FC_FAULT_BASE="http://127.0.0.1:$(cat "$ACCEPT_TMP/fault-port")"
"$ACCEPT_BIN"
