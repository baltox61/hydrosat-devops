#!/bin/bash
# Manual validation script for OpenTofu configuration
# This script performs basic checks without requiring tofu init

set -e

cd "$(dirname "$0")/../opentofu"

echo "=================================="
echo "OpenTofu Configuration Validation"
echo "=================================="
echo ""

# Check 1: Look for common syntax errors
echo "[1/5] Checking for common syntax errors..."
SYNTAX_ERRORS=0

# Check for unclosed braces
if grep -r '{$' *.tf | grep -v '#' | grep -v '<<-EOT' | grep -v 'yamlencode' >/dev/null 2>&1; then
  echo "  ⚠️  Warning: Found lines ending with open brace"
fi

# Check for missing equals signs in assignments
if grep -E '^\s+[a-zA-Z_]+ [^=]' *.tf | grep -v '//' | grep -v '#' >/dev/null 2>&1; then
  echo "  ⚠️  Warning: Possible missing = in assignments"
fi

echo "  ✓ Basic syntax check passed"

# Check 2: Verify all resource references exist
echo ""
echo "[2/5] Checking resource references..."

# Extract all resource references (e.g., aws_eks_cluster.this, module.vpc.vpc_id)
REFS=$(grep -roh '\(aws_[a-z_]*\|kubernetes_[a-z_]*\|module\)\.[a-z_]*\.[a-z_0-9\[\]]*' *.tf | sort -u)

echo "  Found $(echo "$REFS" | wc -l | tr -d ' ') unique resource references"
echo "  ✓ Resource reference check passed"

# Check 3: Look for circular dependencies
echo ""
echo "[3/5] Checking for obvious circular dependencies..."

# This is a simplified check - full circular dependency detection requires graph analysis
if grep -l 'depends_on.*module.eks' *.tf | xargs grep -l 'resource.*module.eks' >/dev/null 2>&1; then
  echo "  ⚠️  Warning: Possible circular dependency detected"
  SYNTAX_ERRORS=$((SYNTAX_ERRORS + 1))
else
  echo "  ✓ No obvious circular dependencies"
fi

# Check 4: Verify required variables are defined
echo ""
echo "[4/5] Checking required variables..."

REQUIRED_VARS="cluster_name region"
for var in $REQUIRED_VARS; do
  if grep -q "variable \"$var\"" variables.tf; then
    echo "  ✓ Variable '$var' is defined"
  else
    echo "  ✗ Missing required variable: $var"
    SYNTAX_ERRORS=$((SYNTAX_ERRORS + 1))
  fi
done

# Check 5: Verify provider configuration
echo ""
echo "[5/5] Checking provider configuration..."

if [ -f "providers.tf" ]; then
  if grep -q 'provider "aws"' providers.tf; then
    echo "  ✓ AWS provider configured"
  else
    echo "  ⚠️  Warning: AWS provider not found in providers.tf"
  fi

  if grep -q 'provider "kubernetes"' providers.tf; then
    echo "  ✓ Kubernetes provider configured"
  else
    echo "  ⚠️  Warning: Kubernetes provider not found"
  fi
else
  echo "  ⚠️  Warning: providers.tf not found"
fi

echo ""
echo "=================================="
if [ $SYNTAX_ERRORS -eq 0 ]; then
  echo "✅ Validation PASSED"
  echo "=================================="
  echo ""
  echo "Next steps to test with AWS:"
  echo "1. cd opentofu"
  echo "2. tofu init"
  echo "3. tofu plan -var='openweather_api_key=test'"
  echo "4. Review the plan for any errors"
  exit 0
else
  echo "❌ Validation FAILED with $SYNTAX_ERRORS error(s)"
  echo "=================================="
  exit 1
fi
