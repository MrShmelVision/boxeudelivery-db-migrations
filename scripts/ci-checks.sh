#!/usr/bin/env bash
# Repository-owned application/configuration checks; no publication or deployment.
set -euo pipefail
cd "$(dirname "$0")/.."
git diff --check
