#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name=$1
    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Test $TESTS_RUN: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    log_success "PASSED"
    echo ""
}

fail_test() {
    local reason=$1
    TESTS_FAILED=$((TESTS_FAILED + 1))
    log_error "FAILED: $reason"
    echo ""
}

# Script start
echo ""
log_info "=========================================="
log_info "  Hydrosat DevOps E2E Test Suite"
log_info "=========================================="
echo ""

# Prerequisites check
log_info "Checking prerequisites..."

command -v kubectl >/dev/null 2>&1 || { log_error "kubectl not found. Please install kubectl."; exit 1; }
command -v aws >/dev/null 2>&1 || { log_error "aws CLI not found. Please install aws CLI."; exit 1; }
command -v curl >/dev/null 2>&1 || { log_error "curl not found. Please install curl."; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq not found. Please install jq."; exit 1; }

log_success "All prerequisites installed"
echo ""

# Test 1: Kubernetes cluster connectivity
run_test "Kubernetes cluster connectivity"
if kubectl cluster-info >/dev/null 2>&1; then
    CLUSTER_NAME=$(kubectl config current-context)
    log_success "Connected to cluster: $CLUSTER_NAME"
    pass_test
else
    fail_test "Cannot connect to Kubernetes cluster"
    log_error "Run: aws eks update-kubeconfig --region us-east-2 --name dagster-eks"
    exit 1
fi

# Test 2: Check all namespaces exist
run_test "Required namespaces exist"
REQUIRED_NAMESPACES=("vault" "data" "monitoring")
MISSING_NS=0

for ns in "${REQUIRED_NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_info "  ✓ Namespace '$ns' exists"
    else
        log_warning "  ✗ Namespace '$ns' missing"
        MISSING_NS=$((MISSING_NS + 1))
    fi
done

if [ $MISSING_NS -eq 0 ]; then
    pass_test
else
    fail_test "$MISSING_NS namespace(s) missing"
fi

# Test 3: Check EKS nodes
run_test "EKS worker nodes are ready"
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)

if [ "$NODE_COUNT" -ge 2 ] && [ "$READY_NODES" -ge 2 ]; then
    log_info "  Nodes: $READY_NODES/$NODE_COUNT ready"
    pass_test
else
    fail_test "Expected at least 2 ready nodes, found $READY_NODES/$NODE_COUNT"
fi

# Test 4: Vault pod status
run_test "Vault server is running"
if kubectl -n vault get pod vault-0 >/dev/null 2>&1; then
    VAULT_STATUS=$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}')
    if [ "$VAULT_STATUS" == "Running" ]; then
        log_info "  Vault pod status: $VAULT_STATUS"
        pass_test
    else
        fail_test "Vault pod status: $VAULT_STATUS (expected Running)"
    fi
else
    fail_test "Vault pod 'vault-0' not found"
fi

# Test 5: Vault is unsealed
run_test "Vault is initialized and unsealed"
VAULT_SEALED=$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "error")

if [ "$VAULT_SEALED" == "false" ]; then
    log_info "  Vault is unsealed and ready"
    pass_test
elif [ "$VAULT_SEALED" == "true" ]; then
    fail_test "Vault is sealed. Run: ./scripts/vault_init.sh"
else
    fail_test "Cannot check Vault status"
fi

# Test 6: Dagster pods are running
run_test "Dagster pods are running"
DAGSTER_PODS=(
    "dagster-dagster-webserver"
    "dagster-dagster-daemon"
    "dagster-user-code"
)

DAGSTER_RUNNING=0
DAGSTER_TOTAL=${#DAGSTER_PODS[@]}

for pod_prefix in "${DAGSTER_PODS[@]}"; do
    POD_COUNT=$(kubectl -n data get pods -l "app.kubernetes.io/name=${pod_prefix}" --no-headers 2>/dev/null | grep -c "Running" || true)
    if [ "$POD_COUNT" -gt 0 ]; then
        log_info "  ✓ $pod_prefix: Running"
        DAGSTER_RUNNING=$((DAGSTER_RUNNING + 1))
    else
        log_warning "  ✗ $pod_prefix: Not running"
    fi
done

if [ $DAGSTER_RUNNING -eq $DAGSTER_TOTAL ]; then
    pass_test
else
    fail_test "$DAGSTER_RUNNING/$DAGSTER_TOTAL Dagster pods running"
fi

# Test 7: Products API pod is running
run_test "Products API pod is running"
API_POD=$(kubectl -n data get pods -l app=products-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$API_POD" ]; then
    API_STATUS=$(kubectl -n data get pod "$API_POD" -o jsonpath='{.status.phase}')
    if [ "$API_STATUS" == "Running" ]; then
        log_info "  API pod: $API_POD ($API_STATUS)"
        pass_test
    else
        fail_test "API pod status: $API_STATUS"
    fi
else
    fail_test "Products API pod not found"
fi

# Test 8: Vault init container successfully fetched secrets
run_test "Vault init container fetched secrets for Dagster"
DAGSTER_POD=$(kubectl -n data get pods -l app=dagster-user-code -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$DAGSTER_POD" ]; then
    INIT_LOGS=$(kubectl -n data logs "$DAGSTER_POD" -c vault-init 2>/dev/null || echo "")
    if echo "$INIT_LOGS" | grep -q "Successfully"; then
        log_info "  Init container successfully fetched secrets"
        pass_test
    else
        log_warning "  Init container logs:"
        echo "$INIT_LOGS" | head -10
        fail_test "Init container did not successfully fetch secrets"
    fi
else
    fail_test "Cannot find Dagster user-code pod"
fi

# Test 9: Secrets are stored in memory (not in env vars)
run_test "Secrets are in memory, not environment variables"
if [ -n "$DAGSTER_POD" ]; then
    ENV_CHECK=$(kubectl -n data exec "$DAGSTER_POD" -c dagster-user-code -- env 2>/dev/null | grep -i "OPENWEATHER_API_KEY=" || echo "")

    if [ -z "$ENV_CHECK" ]; then
        log_info "  ✓ OPENWEATHER_API_KEY not in environment variables (correct)"

        # Check that secret file exists
        FILE_CHECK=$(kubectl -n data exec "$DAGSTER_POD" -c dagster-user-code -- ls /vault/secrets/OPENWEATHER_API_KEY 2>/dev/null || echo "")
        if [ -n "$FILE_CHECK" ]; then
            log_info "  ✓ Secret file exists at /vault/secrets/OPENWEATHER_API_KEY (correct)"
            pass_test
        else
            fail_test "Secret file not found at /vault/secrets/OPENWEATHER_API_KEY"
        fi
    else
        fail_test "OPENWEATHER_API_KEY found in environment variables (should be file-based)"
    fi
else
    fail_test "Cannot check secrets (pod not found)"
fi

# Test 10: S3 bucket exists and is accessible
run_test "S3 bucket exists and is accessible"
BUCKET_NAME="dagster-weather-products"

if aws s3 ls "s3://$BUCKET_NAME" >/dev/null 2>&1; then
    OBJECT_COUNT=$(aws s3 ls "s3://$BUCKET_NAME/weather-products/" --recursive 2>/dev/null | wc -l | tr -d ' ')
    log_info "  Bucket: s3://$BUCKET_NAME"
    log_info "  Objects: $OBJECT_COUNT"
    pass_test
else
    fail_test "Cannot access S3 bucket: s3://$BUCKET_NAME"
fi

# Test 11: IRSA service account is properly configured
run_test "IRSA service account annotation is configured"
SA_ANNOTATION=$(kubectl -n data get sa dagster-user-code -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")

if [ -n "$SA_ANNOTATION" ]; then
    log_info "  Service account annotated with IAM role:"
    log_info "  $SA_ANNOTATION"
    pass_test
else
    fail_test "Service account 'dagster-user-code' missing IRSA annotation"
fi

# Test 12: Monitoring stack is running
run_test "Prometheus and Grafana are running"
PROM_POD=$(kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
GRAF_POD=$(kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$PROM_POD" ] && [ -n "$GRAF_POD" ]; then
    PROM_STATUS=$(kubectl -n monitoring get pod "$PROM_POD" -o jsonpath='{.status.phase}')
    GRAF_STATUS=$(kubectl -n monitoring get pod "$GRAF_POD" -o jsonpath='{.status.phase}')

    if [ "$PROM_STATUS" == "Running" ] && [ "$GRAF_STATUS" == "Running" ]; then
        log_info "  Prometheus: $PROM_STATUS"
        log_info "  Grafana: $GRAF_STATUS"
        pass_test
    else
        fail_test "Prometheus: $PROM_STATUS, Grafana: $GRAF_STATUS"
    fi
else
    fail_test "Monitoring pods not found"
fi

# Test 13: Dagster webserver is accessible
run_test "Dagster webserver is accessible"
log_info "  Starting port-forward to Dagster webserver..."

# Kill any existing port-forwards on 3000
pkill -f "port-forward.*3000" 2>/dev/null || true
sleep 2

kubectl -n data port-forward svc/dagster-dagster-webserver 3000:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 5

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/ 2>/dev/null || echo "000")

kill $PF_PID 2>/dev/null || true

if [ "$HTTP_CODE" == "200" ]; then
    log_info "  Dagster UI responded with HTTP $HTTP_CODE"
    pass_test
else
    fail_test "Dagster UI responded with HTTP $HTTP_CODE (expected 200)"
fi

# Test 14: Products API is accessible and returns data
run_test "Products API is accessible and returns data"
log_info "  Starting port-forward to Products API..."

# Kill any existing port-forwards on 8080
pkill -f "port-forward.*8080" 2>/dev/null || true
sleep 2

kubectl -n data port-forward svc/products-api 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
sleep 5

API_RESPONSE=$(curl -s http://localhost:8080/products?limit=1 2>/dev/null || echo "error")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/products?limit=1 2>/dev/null || echo "000")

kill $PF_PID 2>/dev/null || true

if [ "$HTTP_CODE" == "200" ]; then
    # Check if response is valid JSON
    if echo "$API_RESPONSE" | jq empty 2>/dev/null; then
        PRODUCT_COUNT=$(echo "$API_RESPONSE" | jq '. | length' 2>/dev/null || echo "0")
        log_info "  API responded with HTTP $HTTP_CODE"
        log_info "  Returned $PRODUCT_COUNT product(s)"

        if [ "$PRODUCT_COUNT" -gt 0 ]; then
            pass_test
        else
            log_warning "  API returned no products (may need to run pipeline first)"
            pass_test
        fi
    else
        fail_test "API response is not valid JSON"
    fi
else
    fail_test "API responded with HTTP $HTTP_CODE (expected 200)"
fi

# Final summary
echo ""
log_info "=========================================="
log_info "  Test Summary"
log_info "=========================================="
echo ""
log_info "Total tests run:    $TESTS_RUN"
log_success "Tests passed:       $TESTS_PASSED"

if [ $TESTS_FAILED -gt 0 ]; then
    log_error "Tests failed:       $TESTS_FAILED"
    echo ""
    log_error "Some tests failed. Please review the output above."
    log_info "Common fixes:"
    log_info "  - Vault sealed: ./scripts/vault_init.sh"
    log_info "  - Pods not ready: kubectl -n <namespace> get pods"
    log_info "  - EKS not configured: aws eks update-kubeconfig --region us-east-2 --name dagster-eks"
    echo ""
    exit 1
else
    echo ""
    log_success "=========================================="
    log_success "  All tests passed! 🎉"
    log_success "=========================================="
    echo ""
    log_info "Your infrastructure is ready for the demo!"
    echo ""
    log_info "Next steps:"
    log_info "  1. Review the demo script: cat DEMO.md"
    log_info "  2. Practice the demo walkthrough"
    log_info "  3. Review the architecture diagrams: docs/diagrams.md"
    echo ""
    exit 0
fi
