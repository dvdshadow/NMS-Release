#!/usr/bin/env bash
# Convenience wrapper — run from the repository root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${ROOT}/install/linux/install.sh" "$@"
