#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT_ROOT"

bash -n arch-redeploy lib/*.sh installer/init installer/*.sh tests/run.sh scripts/*.sh
sh -n installer/udhcpc.script
shellcheck -x -P . arch-redeploy lib/*.sh installer/init installer/*.sh tests/run.sh scripts/*.sh
tests/run.sh
