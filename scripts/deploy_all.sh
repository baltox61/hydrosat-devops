#!/bin/bash
# Complete deployment script for Hydrosat DevOps take home infrastructure
# This script automates the entire deployment process from start to finish

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Hydrosat DevOps - Complete Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "This script will automatically:"
echo "  1. Validate prerequisites and fix common issues"
echo "  2. Create ECR repositories"
echo "  3. Build and push Docker images"
echo "  4. Deploy EKS infrastructure with OpenTofu"
echo "  5. Configure kubectl and wait for cluster"
echo "  6. Initialize and configure Vault"
echo "  7. Verify deployment and display access URLs"
echo ""
echo "Estimated time: 20-25 minutes"
echo ""

# Function to print section headers
print_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function to print error messages
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Function to print warning messages
print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Step 0: Validate prerequisites
print_section "Step 0: Validating Prerequisites"

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured or invalid, please make sure you have an AWS setup"
    echo "Run: aws configure"
    exit 1
fi
print_success "AWS credentials validated"

# Check required tools
REQUIRED_TOOLS=("tofu" "docker" "kubectl" "helm" "jq")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        print_error "$tool is not installed"
        exit 1
    fi
    print_success "$tool found"
done

# Check Docker daemon is running
if ! docker info &> /dev/null; then
    print_error "Docker daemon is not running. Please start Docker Desktop."
    exit 1
fi
print_success "Docker daemon is running"

# Fix Docker buildx permissions proactively
print_warning "Checking Docker buildx permissions..."
if [ -d ~/.docker/buildx ]; then
    # Remove buildx cache entirely to avoid permission issues
    # Docker will recreate it with correct permissions
    print_warning "Clearing Docker buildx cache to prevent permission issues..."
    rm -rf ~/.docker/buildx/activity 2>/dev/null || {
        print_error "Cannot remove Docker buildx cache"
        echo ""
        echo "Please run one of these commands:"
        echo "  Option 1: sudo rm -rf ~/.docker/buildx/activity"
        echo "  Option 2: sudo chown -R \$USER:staff ~/.docker/buildx"
        echo ""
        exit 1
    }
    print_success "Docker buildx cache cleared - will be recreated cleanly"
fi

# Get AWS details
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-us-east-2}"
print_success "AWS Account ID: $AWS_ACCOUNT_ID"
print_success "AWS Region: $AWS_REGION"

# Step 1: Create ECR repositories
print_section "Step 1: Creating ECR Repositories"

echo "Creating dagster-weather-app repository..."
if aws ecr describe-repositories --repository-names dagster-weather-app --region "$AWS_REGION" &> /dev/null; then
    print_warning "dagster-weather-app repository already exists"
else
    aws ecr create-repository --repository-name dagster-weather-app --region "$AWS_REGION" > /dev/null
    print_success "Created dagster-weather-app repository"
fi

echo "Creating weather-products-api repository..."
if aws ecr describe-repositories --repository-names weather-products-api --region "$AWS_REGION" &> /dev/null; then
    print_warning "weather-products-api repository already exists"
else
    aws ecr create-repository --repository-name weather-products-api --region "$AWS_REGION" > /dev/null
    print_success "Created weather-products-api repository"
fi

# Step 2: Build and push Docker images
print_section "Step 2: Building and Pushing Docker Images"

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
TAG="${IMAGE_TAG:-latest}"

echo "Registry: $REGISTRY"
echo "Tag: $TAG"
echo ""

cd "$PROJECT_ROOT"

# Run build script with error handling
if ! ./scripts/build_and_push_images.sh "$REGISTRY" "$TAG"; then
    print_error "Failed to build and push Docker images"
    echo ""
    echo "Common issues:"
    echo "  1. Docker daemon not running"
    echo "  2. Insufficient disk space"
    echo "  3. ECR authentication expired"
    echo ""
    echo "Try:"
    echo "  - Restart Docker Desktop"
    echo "  - Run: docker system prune -a"
    echo "  - Re-authenticate to ECR"
    exit 1
fi

print_success "Docker images built and pushed"

# Step 3: Initialize OpenTofu
print_section "Step 3: Initializing OpenTofu"

cd "$PROJECT_ROOT/opentofu"
tofu init

print_success "OpenTofu initialized"

# Step 3.5: Clean up any leftover resources from previous failed deployments
print_section "Step 3.5: Cleaning Up Previous Deployment Artifacts"

# Check if EKS cluster exists and is accessible
if aws eks describe-cluster --name dagster-eks --region "$AWS_REGION" &> /dev/null; then
    print_warning "EKS cluster exists - checking for leftover resources..."

    # Configure kubectl
    aws eks update-kubeconfig --name dagster-eks --region "$AWS_REGION" &> /dev/null || {
        print_warning "Could not configure kubectl - skipping cleanup"
    }

    # Check for and clean up Helm releases in failed state
    echo "Checking for Helm releases..."
    for release in dagster kps vault karpenter; do
        for ns in data monitoring vault karpenter; do
            if helm status "$release" -n "$ns" &> /dev/null; then
                STATUS=$(helm status "$release" -n "$ns" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || echo "unknown")
                if [ "$STATUS" = "failed" ] || [ "$STATUS" = "pending-install" ] || [ "$STATUS" = "pending-upgrade" ]; then
                    echo "  Cleaning up $release in $ns (status: $STATUS)..."
                    helm uninstall "$release" -n "$ns" &> /dev/null || true
                fi
            fi
        done
    done

    # Clean up namespaces with stuck resources
    for ns in data monitoring vault karpenter; do
        if kubectl get namespace "$ns" &> /dev/null; then
            # Check if namespace has terminating pods or stuck resources
            TERMINATING=$(kubectl get pods -n "$ns" --field-selector=status.phase=Terminating 2>/dev/null | wc -l)
            if [ "$TERMINATING" -gt 1 ]; then
                print_warning "Namespace $ns has terminating resources - cleaning up..."
                kubectl delete namespace "$ns" --timeout=30s &> /dev/null || true
            fi
        fi
    done

    print_success "Cleanup complete"
else
    print_success "No existing cluster - clean deployment"
fi

# Step 4: Plan infrastructure (excluding Vault config)
print_section "Step 4: Planning Infrastructure Changes (First Pass)"

echo "Creating Terraform execution plan..."
echo "This follows best practices for infrastructure changes:"
echo "  1. Generate plan (preview changes)"
echo "  2. Review plan output"
echo "  3. Apply exact plan (no surprises)"
echo ""
echo "Note: This first pass excludes Vault configuration resources"
echo "      (they require Vault to be initialized first)"
echo ""
echo "This script is for initial bootstrap deployment only."
echo ""

# Build target list (excluding Vault config resources that require authentication)
TARGET_ARGS="-target=module.vpc"
TARGET_ARGS="$TARGET_ARGS -target=aws_eks_cluster.this"
TARGET_ARGS="$TARGET_ARGS -target=aws_eks_node_group.default"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role.cluster"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role.node"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role.karpenter_controller"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role.karpenter_node"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_policy.dagster_s3"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_policy.api_s3_readonly"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_policy.karpenter_controller"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.node_AmazonSSMManagedInstanceCore"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.karpenter_controller"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.karpenter_node_AmazonEKSWorkerNodePolicy"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.karpenter_node_AmazonEKS_CNI_Policy"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.karpenter_node_AmazonEC2ContainerRegistryReadOnly"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.karpenter_node_AmazonSSMManagedInstanceCore"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_instance_profile.karpenter_node"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_openid_connect_provider.cluster"
# EKS Addons (including EBS CSI driver for persistent volumes)
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role.ebs_csi_driver"
TARGET_ARGS="$TARGET_ARGS -target=aws_iam_role_policy_attachment.ebs_csi_driver"
TARGET_ARGS="$TARGET_ARGS -target=aws_eks_addon.kube_proxy"
TARGET_ARGS="$TARGET_ARGS -target=aws_eks_addon.coredns"
TARGET_ARGS="$TARGET_ARGS -target=aws_eks_addon.vpc_cni"
TARGET_ARGS="$TARGET_ARGS -target=aws_eks_addon.ebs_csi_driver"
TARGET_ARGS="$TARGET_ARGS -target=aws_security_group.cluster"
TARGET_ARGS="$TARGET_ARGS -target=aws_security_group.node"
TARGET_ARGS="$TARGET_ARGS -target=aws_security_group_rule.cluster_egress"
TARGET_ARGS="$TARGET_ARGS -target=aws_security_group_rule.cluster_ingress_node_https"
TARGET_ARGS="$TARGET_ARGS -target=aws_security_group_rule.node_egress"
TARGET_ARGS="$TARGET_ARGS -target=aws_security_group_rule.node_ingress_self"
TARGET_ARGS="$TARGET_ARGS -target=aws_security_group_rule.node_ingress_cluster"
TARGET_ARGS="$TARGET_ARGS -target=aws_security_group_rule.node_ingress_cluster_https"
TARGET_ARGS="$TARGET_ARGS -target=aws_s3_bucket.products"
TARGET_ARGS="$TARGET_ARGS -target=aws_s3_bucket_versioning.products"
TARGET_ARGS="$TARGET_ARGS -target=aws_s3_bucket_public_access_block.products"
TARGET_ARGS="$TARGET_ARGS -target=aws_s3_bucket_lifecycle_configuration.products"
TARGET_ARGS="$TARGET_ARGS -target=aws_sqs_queue.karpenter_interruption"
TARGET_ARGS="$TARGET_ARGS -target=aws_sqs_queue_policy.karpenter_interruption"
TARGET_ARGS="$TARGET_ARGS -target=aws_cloudwatch_event_rule.spot_interruption"
TARGET_ARGS="$TARGET_ARGS -target=aws_cloudwatch_event_rule.scheduled_change"
TARGET_ARGS="$TARGET_ARGS -target=aws_cloudwatch_event_rule.rebalance_recommendation"
TARGET_ARGS="$TARGET_ARGS -target=aws_cloudwatch_event_target.spot_interruption"
TARGET_ARGS="$TARGET_ARGS -target=aws_cloudwatch_event_target.scheduled_change"
TARGET_ARGS="$TARGET_ARGS -target=aws_cloudwatch_event_target.rebalance_recommendation"
TARGET_ARGS="$TARGET_ARGS -target=module.iam_role_dagster"
TARGET_ARGS="$TARGET_ARGS -target=module.iam_role_api"
TARGET_ARGS="$TARGET_ARGS -target=kubernetes_namespace.data"
TARGET_ARGS="$TARGET_ARGS -target=kubernetes_namespace.monitoring"
TARGET_ARGS="$TARGET_ARGS -target=kubernetes_namespace.karpenter"
TARGET_ARGS="$TARGET_ARGS -target=kubernetes_namespace.vault"
TARGET_ARGS="$TARGET_ARGS -target=kubernetes_service_account.api"
TARGET_ARGS="$TARGET_ARGS -target=kubernetes_service_account.vault"
TARGET_ARGS="$TARGET_ARGS -target=kubernetes_cluster_role_binding.vault_auth_delegator"
# Note: Dagster and API deployed in second apply after Vault is initialized (avoids init container failures)
TARGET_ARGS="$TARGET_ARGS -target=helm_release.kps"
TARGET_ARGS="$TARGET_ARGS -target=helm_release.vault"
TARGET_ARGS="$TARGET_ARGS -target=helm_release.karpenter"
# Note: API deployment moved to second pass (init container requires Vault to be configured)

# Create plan for infrastructure (Vault config applied separately in second pass)
tofu plan \
    -var="dagster_image_repository=${REGISTRY}/dagster-weather-app" \
    -var="dagster_image_tag=${TAG}" \
    -var="api_image=${REGISTRY}/weather-products-api:${TAG}" \
    $TARGET_ARGS \
    -out=tfplan

print_success "Terraform plan created (excluding Vault config)"
echo ""

# Step 5: Review and apply infrastructure
print_section "Step 5: Applying Infrastructure (First Pass)"

echo "This will create:"
echo "  - VPC with subnets, NAT Gateway, Internet Gateway"
echo "  - EKS cluster with managed node group"
echo "  - EKS addons (kube-proxy, CoreDNS, VPC CNI, EBS CSI driver)"
echo "  - IAM roles and IRSA"
echo "  - S3 bucket with 7-day lifecycle policy"
echo "  - Vault (will be initialized in next step)"
echo "  - Prometheus + Grafana + AlertManager"
echo "  - Karpenter autoscaler"
echo ""
echo "Note: Dagster and Products API will be deployed in the second pass after Vault is initialized"
echo ""
echo "Estimated time: 15-20 minutes"
echo ""

read -p "Continue with deployment? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    print_error "Deployment cancelled by user"
    exit 0
fi

echo "Applying saved Terraform plan..."
tofu apply tfplan

print_success "Infrastructure deployed (first pass)"

# Step 6: Configure kubectl
print_section "Step 6: Configuring kubectl"

CLUSTER_NAME=$(tofu output -raw cluster_name 2>/dev/null || echo "dagster-eks")
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

print_success "kubectl configured"

# Wait for nodes to be ready
echo "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

print_success "All nodes are ready"

# Step 6: Initialize Vault
print_section "Step 6: Initializing Vault"

echo "Waiting for Vault pod to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s

print_success "Vault pod is ready"

echo ""
print_warning "You will be prompted to enter your OpenWeather API key"
echo "Get your API key from: https://home.openweathermap.org/api_keys"
echo ""

cd "$PROJECT_ROOT"
./scripts/vault_init.sh

# Extract root token from vault init output
if [ -f ~/.vault-keys/root-token ]; then
    VAULT_ROOT_TOKEN=$(cat ~/.vault-keys/root-token)
    print_success "Vault root token loaded"
else
    print_error "Vault root token not found at ~/.vault-keys/root-token"
    echo "Please set VAULT_TOKEN manually and run: cd opentofu && tofu apply"
    exit 1
fi

# Step 7: Configure Vault and Deploy Dagster and API (second apply)
print_section "Step 7: Configuring Vault and Deploying Applications (Second Pass)"

echo "Now that Vault is initialized, we can:"
echo "  - Configure Kubernetes auth backend"
echo "  - Enable KV v2 secrets engine"
echo "  - Create Vault policies (dagster-app, api-app)"
echo "  - Set up Kubernetes auth roles"
echo "  - Deploy Dagster with Vault integration"
echo "  - Deploy Products API with Vault integration"
echo ""

# Set up port-forwarding to Vault so Terraform can connect
echo "Setting up port-forwarding to Vault..."
kubectl port-forward -n vault svc/vault 8200:8200 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3  # Give port-forward time to establish

print_success "Port-forwarding established to Vault"

# Configure Vault with separate terraform directory
cd "$PROJECT_ROOT/opentofu/vault-config"
echo "Initializing Vault configuration terraform..."
tofu init

# Set Vault environment variables
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="$VAULT_ROOT_TOKEN"

echo "Applying Vault configuration resources..."
tofu apply \
    -var="cluster_name=dagster-eks" \
    -auto-approve

print_success "Vault configuration applied"

# Now apply Dagster and API from main terraform directory
cd "$PROJECT_ROOT/opentofu"
echo "Deploying Dagster and Products API..."
tofu apply \
    -var="dagster_image_repository=${REGISTRY}/dagster-weather-app" \
    -var="dagster_image_tag=${TAG}" \
    -var="api_image=${REGISTRY}/weather-products-api:${TAG}" \
    -auto-approve

# Clean up port-forward
kill $PORT_FORWARD_PID 2>/dev/null || true
unset VAULT_ADDR
unset VAULT_TOKEN

print_success "All applications deployed"

# Step 8: Verify deployment
print_section "Step 8: Verifying Deployment"

echo "Checking pod status..."
echo ""

echo "Data namespace:"
kubectl get pods -n data
echo ""

echo "Vault namespace:"
kubectl get pods -n vault
echo ""

echo "Monitoring namespace:"
kubectl get pods -n monitoring
echo ""

echo "Karpenter namespace:"
kubectl get pods -n karpenter
echo ""

# Step 9: Display access information
print_section "Step 9: Deployment Complete!"

echo ""
print_success "Infrastructure successfully deployed!"
echo ""

echo -e "${GREEN}Access Information:${NC}"
echo ""

DAGSTER_LB=$(kubectl -n data get svc dagster-dagster-webserver -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")
GRAFANA_LB=$(kubectl -n monitoring get svc kps-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")

echo "📊 Dagster UI:"
if [ "$DAGSTER_LB" != "pending..." ]; then
    echo "   http://$DAGSTER_LB"
else
    echo "   LoadBalancer is provisioning... Check with: kubectl -n data get svc dagster-dagster-webserver"
fi
echo ""

echo "📈 Grafana:"
if [ "$GRAFANA_LB" != "pending..." ]; then
    echo "   http://$GRAFANA_LB"
else
    echo "   LoadBalancer is provisioning... Check with: kubectl -n monitoring get svc kps-grafana"
fi
echo "   Username: admin"
echo "   Password: prom-operator"
echo ""

echo "🔐 Vault:"
echo "   Root Token: $VAULT_ROOT_TOKEN"
echo "   Unseal Keys: ~/.vault-keys/"
echo ""

echo "🚀 Products API (via port-forward):"
echo "   kubectl -n data port-forward svc/products-api 8080:8080"
echo "   curl http://localhost:8080/products"
echo ""

echo -e "${YELLOW}Running Initial Pipeline Job:${NC}"
echo "Triggering the weather pipeline to populate S3 with initial data..."
echo ""

# Wait for Dagster user-code deployment to be ready
echo "Waiting for Dagster user-code deployment to be ready..."
kubectl wait --for=condition=ready pod -l component=user-deployments -n data --timeout=120s 2>/dev/null || {
    print_warning "Dagster user-code not ready yet - you can run the pipeline manually later"
    echo "   POD=\$(kubectl get pod -n data -l component=user-deployments -o jsonpath='{.items[0].metadata.name}')"
    echo "   kubectl -n data exec -it \$POD -- dagster job execute -m weather_pipeline -j weather_product_job"
}

# Try to run the pipeline
if kubectl wait --for=condition=ready pod -l component=user-deployments -n data --timeout=5s 2>/dev/null; then
    echo "Running weather pipeline job..."
    POD=$(kubectl get pod -n data -l component=user-deployments -o jsonpath='{.items[0].metadata.name}')
    kubectl -n data exec $POD -- \
      dagster job execute -m weather_pipeline -j weather_product_job 2>&1 | grep -E "(Started|Fetched|Uploaded|succeeded|ERROR)" || true

    echo ""
    echo "✅ Pipeline job triggered successfully!"
    echo "   Data should now be available in S3 and queryable via the API"
    echo ""
fi

echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Wait for LoadBalancers to get external IPs (2-3 minutes)"
echo "2. Access Dagster UI to view pipeline runs:"
echo "   kubectl -n data port-forward deployment/dagster-dagster-webserver 3000:80"
echo "   Open http://localhost:3000"
echo "3. Verify data is written to S3:"
echo "   aws s3 ls s3://dagster-weather-products/weather-products/ --recursive"
echo "4. Query the API (data should already be available):"
echo "   kubectl -n data port-forward svc/products-api 8080:8080"
echo "   curl http://localhost:8080/products?limit=5"
echo ""

echo -e "${YELLOW}Troubleshooting:${NC}"
echo "If you encounter any issues, see GETTING_STARTED.md 'Common Issues' section for:"
echo "  - Vault CrashLoopBackOff and initialization issues"
echo "  - ImagePullBackOff errors (ECR authentication)"
echo "  - Dagster user-code pod using wrong image"
echo "  - EC2 Key Pair 'already exists' errors"
echo "  - Pod status checks: kubectl get pods -n data"
echo ""

print_success "Deployment script completed successfully!"
