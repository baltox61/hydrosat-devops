#!/bin/bash
# Quick script to check and fix Vault secrets

set -e

export AWS_PROFILE=balto

echo "=== Checking Vault Status ==="
kubectl -n vault get pods

echo ""
echo "=== Setting up port-forward to Vault ==="
kubectl -n vault port-forward svc/vault 8200:8200 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

echo "=== Loading Vault credentials ==="
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN=$(cat ~/.vault-keys/vault-init-20251020-104626.json | jq -r '.root_token')

echo "Vault Token: ${VAULT_TOKEN:0:10}..."

echo ""
echo "=== Checking if KV engine is enabled ==="
if vault secrets list | grep -q "secret/"; then
    echo "✓ KV v2 secrets engine is enabled"
else
    echo "✗ KV v2 secrets engine NOT enabled - enabling now..."
    vault secrets enable -path=secret kv-v2
    echo "✓ KV v2 secrets engine enabled"
fi

echo ""
echo "=== Checking existing secrets ==="
if vault kv list secret/ 2>/dev/null; then
    echo ""
    echo "=== Listing secrets in dagster-eks path ==="
    vault kv list secret/dagster-eks/ 2>/dev/null || echo "No dagster-eks secrets found"

    echo ""
    echo "=== Listing secrets in dagster path ==="
    vault kv list secret/dagster/ 2>/dev/null || echo "No dagster secrets found"

    echo ""
    echo "=== Listing secrets in api path ==="
    vault kv list secret/api/ 2>/dev/null || echo "No api secrets found"
else
    echo "No secrets found - need to populate"
fi

echo ""
read -p "Do you want to populate/recreate all secrets now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    read -p "Enter OpenWeather API key: " OPENWEATHER_API_KEY

    echo ""
    echo "Creating secrets..."

    vault kv put secret/dagster-eks/openweather-api-key key="$OPENWEATHER_API_KEY"
    echo "✓ Created secret/dagster-eks/openweather-api-key"

    vault kv put secret/dagster-eks/postgres/dagster-db-password password="changeme-dagster-password"
    echo "✓ Created secret/dagster-eks/postgres/dagster-db-password"

    vault kv put secret/dagster-eks/aws/s3-bucket-name bucket="dagster-weather-products"
    echo "✓ Created secret/dagster-eks/aws/s3-bucket-name"

    vault kv put secret/dagster/pipeline-config fetch_interval="3600"
    echo "✓ Created secret/dagster/pipeline-config"

    vault kv put secret/dagster/coordinates lat="40.7128" lon="-74.0060"
    echo "✓ Created secret/dagster/coordinates"

    vault kv put secret/api/rate-limits max_requests="100"
    echo "✓ Created secret/api/rate-limits"

    echo ""
    echo "=== All secrets created! ==="
fi

# Kill port-forward
kill $PF_PID 2>/dev/null || true

echo ""
echo "=== Done! ==="
