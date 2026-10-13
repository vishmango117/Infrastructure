#!/bin/sh
# Scans text before it is published outside git (issue bodies, comments, PR text).
# Usage: scripts/scan-text.sh FILE...   (or pipe text on stdin)
config=$(sh scripts/gitleaks-config.sh)
if [ $# -eq 0 ]; then
  exec gitleaks stdin --redact --no-banner --config "$config"
fi
status=0
for f in "$@"; do
  gitleaks stdin --redact --no-banner --config "$config" < "$f" || status=1
done
exit $status
