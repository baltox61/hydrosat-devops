#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT/opentofu"

echo ">> Running OpenTofu fmt/validate/tflint/tfsec/checkov"
tofu fmt -recursive
tofu validate

if command -v tflint >/dev/null 2>&1; then
  tflint --init
  tflint
else
  echo "tflint not found (skip)"
fi

if command -v tfsec >/dev/null 2>&1; then
  tfsec .
else
  echo "tfsec not found (skip)"
fi

if command -v checkov >/dev/null 2>&1; then
  checkov -d .
else
  echo "checkov not found (skip)"
fi

echo ">> Audit complete."
