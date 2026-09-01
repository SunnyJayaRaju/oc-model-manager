#!/usr/bin/env bash
# Backward compatibility shim for oc-model-audit.sh v1
# Maps old flags to new ocprobe commands

set -euo pipefail

# Source shared shim helpers
# shellcheck source=../lib/shim_helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/shim_helpers.sh"

QUICK=0
APPLY=0

for arg in "$@"; do
	case "$arg" in
	--help | -h)
		echo "Usage: oc-model-audit.sh [--quick] [--apply]"
		echo "  --quick  Skip whitelist probe"
		echo "  --apply  Apply changes to config"
		exit 0
		;;
	--quick) QUICK=1 ;;
	--apply) APPLY=1 ;;
	*)
		echo "unknown flag: $arg" >&2
		exit 1
		;;
	esac
done

if [[ $APPLY -eq 1 ]]; then
	exec ocprobe audit ${QUICK:+--quick} --yes
else
	exec ocprobe check ${QUICK:+--quick}
fi
