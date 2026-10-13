#!/bin/sh
# Prints the gitleaks config to use: the private one (real names, gitignored) when present,
# otherwise the public one with a warning, because name checks are then skipped.
if [ -f docs/private/gitleaks.private.toml ]; then
  echo docs/private/gitleaks.private.toml
else
  echo "gitleaks: docs/private/gitleaks.private.toml missing; real-name rules NOT checked" >&2
  echo .gitleaks.toml
fi
