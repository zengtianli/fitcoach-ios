#!/bin/bash
# Production client/API privacy boundaries against a disposable local tenant DB.
set -euo pipefail
source "$(dirname "$0")/_common"
accept_compile scripts/accept/privacy/PrivacyCheck.swift
accept_start_backend
"$ACCEPT_BIN"
