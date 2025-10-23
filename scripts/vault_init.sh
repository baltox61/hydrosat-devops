#!/bin/bash
# Vault initialization and unsealing script
# This script should be run ONCE after deploying Vault for the first time
# It will initialize Vault, unseal it, and populate initial secrets

set -e

echo "==================================="
echo "Vault Initialization Script"
echo "==================================="
echo ""

# Check if kubectl is configured
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl is not configured or cannot connect to cluster"
  echo "Run: aws eks update-kubeconfig --region <region> --name <cluster-name>"
  exit 1
fi

# Check if Vault pod is running
echo "Checking Vault pod status..."
if ! kubectl -n vault get pod vault-0 &>/dev/null; then
  echo "ERROR: Vault pod 'vault-0' not found in namespace 'vault'"
  echo "Deploy Vault first: cd opentofu && tofu apply -target=helm_release.vault"
  exit 1
fi

# Wait for Vault pod to be ready
echo "Waiting for Vault pod to be ready..."
kubectl -n vault wait --for=condition=ready pod/vault-0 --timeout=300s

# Check if Vault is already initialized
VAULT_STATUS=$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null || echo '{}')
INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')

if [ "$INITIALIZED" = "true" ]; then
  echo ""
  echo "WARNING: Vault is already initialized!"
  echo "If you want to re-initialize (THIS WILL DESTROY ALL DATA), run:"
  echo "  kubectl -n vault exec vault-0 -- vault operator rekey -init"
  echo ""
  read -p "Do you want to continue with unsealing only? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
  SKIP_INIT=true
else
  SKIP_INIT=false
fi

# Initialize Vault (if not already initialized)
if [ "$SKIP_INIT" = "false" ]; then
  echo ""
  echo "Initializing Vault with 5 key shares and threshold of 3..."
  INIT_OUTPUT=$(kubectl -n vault exec vault-0 -- vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json)

  # Extract unseal keys and root token
  UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
  UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
  UNSEAL_KEY_3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
  UNSEAL_KEY_4=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[3]')
  UNSEAL_KEY_5=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[4]')
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

  # Save to files (SECURE THESE!)
  mkdir -p ~/.vault-keys
  echo "$INIT_OUTPUT" > ~/.vault-keys/vault-init-$(date +%Y%m%d-%H%M%S).json
  echo "$ROOT_TOKEN" > ~/.vault-keys/root-token
  chmod 600 ~/.vault-keys/vault-init-*.json
  chmod 600 ~/.vault-keys/root-token

  echo ""
  echo "==================================="
  echo "VAULT INITIALIZATION COMPLETE"
  echo "==================================="
  echo ""
  echo "Root Token: $ROOT_TOKEN"
  echo ""
  echo "Unseal Keys (you need 3 of these to unseal):"
  echo "  Key 1: $UNSEAL_KEY_1"
  echo "  Key 2: $UNSEAL_KEY_2"
  echo "  Key 3: $UNSEAL_KEY_3"
  echo "  Key 4: $UNSEAL_KEY_4"
  echo "  Key 5: $UNSEAL_KEY_5"
  echo ""
  echo "These keys have been saved to: ~/.vault-keys/"
  echo ""
  echo "IMPORTANT: Store these keys securely! You cannot retrieve them later."
  echo "           In production, use AWS KMS auto-unseal instead."
  echo ""
else
  # Ask for unseal keys
  echo ""
  echo "Please provide 3 unseal keys to unseal Vault:"
  read -p "Unseal Key 1: " -s UNSEAL_KEY_1
  echo
  read -p "Unseal Key 2: " -s UNSEAL_KEY_2
  echo
  read -p "Unseal Key 3: " -s UNSEAL_KEY_3
  echo
  read -p "Root Token: " -s ROOT_TOKEN
  echo

  # Save root token for deploy_all.sh to use
  mkdir -p ~/.vault-keys
  echo "$ROOT_TOKEN" > ~/.vault-keys/root-token
  chmod 600 ~/.vault-keys/root-token
fi

# Unseal Vault (requires 3 keys)
echo ""
echo "Unsealing Vault..."
kubectl -n vault exec vault-0 -- vault operator unseal "$UNSEAL_KEY_1" >/dev/null
kubectl -n vault exec vault-0 -- vault operator unseal "$UNSEAL_KEY_2" >/dev/null
kubectl -n vault exec vault-0 -- vault operator unseal "$UNSEAL_KEY_3" >/dev/null

echo "Vault unsealed successfully!"

# Check Vault status
echo ""
echo "Vault Status:"
kubectl -n vault exec vault-0 -- vault status

# Now populate initial secrets
# Always offer to populate secrets, regardless of whether we just initialized
echo ""
read -p "Do you want to populate/update secrets in Vault? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo ""
  echo "==================================="
  echo "Populating Initial Secrets"
  echo "==================================="
  echo ""

  # Set VAULT_TOKEN for commands
  export VAULT_TOKEN="$ROOT_TOKEN"

  # Port-forward Vault service in background
  echo "Starting port-forward to Vault..."
  kubectl -n vault port-forward svc/vault 8200:8200 &>/dev/null &
  PF_PID=$!
  sleep 3

  # Set Vault address
  export VAULT_ADDR="http://localhost:8200"

  # Enable KV v2 secrets engine (required before we can create secrets)
  echo "Enabling KV v2 secrets engine..."
  vault secrets enable -path=secret kv-v2 || echo "KV v2 secrets engine already enabled"
  echo "✓ KV v2 secrets engine ready"
  echo ""

  echo "Loading secrets from JSON..."

  # Load secrets schema
  # Determine script directory to find secrets file
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
  SECRETS_JSON="$PROJECT_ROOT/opentofu/vault-secrets.json"

  if [ ! -f "$SECRETS_JSON" ]; then
    echo "ERROR: Secrets JSON not found at $SECRETS_JSON"
    exit 1
  fi

  # Prompt for required secrets
  read -p "Enter OpenWeather API key: " OPENWEATHER_API_KEY
  read -p "Enter Dagster DB password (default: changeme-dagster-password): " DAGSTER_DB_PASSWORD
  DAGSTER_DB_PASSWORD=${DAGSTER_DB_PASSWORD:-"changeme-dagster-password"}
  read -p "Enter S3 bucket name (default: dagster-weather-products): " PRODUCTS_BUCKET
  PRODUCTS_BUCKET=${PRODUCTS_BUCKET:-"dagster-weather-products"}

  # Get cluster name
  CLUSTER_NAME=${CLUSTER_NAME:-"dagster-eks"}

  # Export vars for envsubst
  export OPENWEATHER_API_KEY DAGSTER_DB_PASSWORD PRODUCTS_BUCKET CLUSTER_NAME

  # Process JSON and populate secrets
  echo "Populating cluster-scoped secrets..."
  vault kv put secret/${CLUSTER_NAME}/openweather-api-key key="$OPENWEATHER_API_KEY"
  echo "✓ Created secret/${CLUSTER_NAME}/openweather-api-key"

  vault kv put secret/${CLUSTER_NAME}/postgres/dagster-db-password password="$DAGSTER_DB_PASSWORD"
  echo "✓ Created secret/${CLUSTER_NAME}/postgres/dagster-db-password"

  vault kv put secret/${CLUSTER_NAME}/aws/s3-bucket-name bucket="$PRODUCTS_BUCKET"
  echo "✓ Created secret/${CLUSTER_NAME}/aws/s3-bucket-name"

  echo "Populating app-specific secrets..."
  vault kv put secret/dagster/pipeline-config fetch_interval="3600"
  echo "✓ Created secret/dagster/pipeline-config"

  vault kv put secret/dagster/coordinates lat="40.7128" lon="-74.0060"
  echo "✓ Created secret/dagster/coordinates"

  vault kv put secret/api/rate-limits max_requests="100"
  echo "✓ Created secret/api/rate-limits"

  # Kill port-forward
  kill $PF_PID 2>/dev/null || true

  echo ""
  echo "==================================="
  echo "Initial secrets populated!"
  echo "==================================="
fi

echo ""
echo "==================================="
echo "Next Steps:"
echo "==================================="
echo ""
echo "1. Save the root token and unseal keys securely"
echo "2. Set VAULT_TOKEN environment variable:"
echo "   export VAULT_TOKEN=$ROOT_TOKEN"
echo ""
echo "3. Apply Vault configuration (Kubernetes auth, policies, roles):"
echo "   cd opentofu"
echo "   export VAULT_TOKEN=$ROOT_TOKEN"
echo "   tofu apply -target=vault_auth_backend.kubernetes"
echo ""
echo "4. Deploy/update applications to use Vault:"
echo "   tofu apply"
echo ""
echo "5. To access Vault UI:"
echo "   kubectl -n vault port-forward svc/vault-ui 8200:8200"
echo "   Open: http://localhost:8200"
echo "   Login with root token: $ROOT_TOKEN"
echo ""
echo "6. In production: Configure AWS KMS auto-unseal"
echo ""
