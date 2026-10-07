#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -x "$root/.venv/bin/python" ]]; then
  echo '缺少本地 Python 环境，请按 docs/LOCAL_TEST.md 安装。' >&2
  exit 1
fi
export PYTHONPATH="$root/backend${PYTHONPATH:+:$PYTHONPATH}"
exec "$root/.venv/bin/python" "$root/scripts/local_runtime.py" "${1:-start}"
