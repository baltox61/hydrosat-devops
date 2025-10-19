#!/bin/bash
# Complete teardown script for Hydrosat DevOps infrastructure
# Usage: ./teardown_all.sh [--force]
#   --force: Skip confirmations and use direct AWS cleanup (bypasses Terraform)

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

# Parse arguments
FORCE_MODE=false
if [ "$1" == "--force" ]; then
    FORCE_MODE=true
fi

echo -e "${RED}========================================${NC}"
if [ "$FORCE_MODE" = true ]; then
    echo -e "${RED}Hydrosat DevOps - FORCE TEARDOWN${NC}"
    echo -e "${RED}(Bypassing Terraform, using direct AWS cleanup)${NC}"
else
    echo -e "${RED}Hydrosat DevOps - Infrastructure Teardown${NC}"
fi
echo -e "${RED}========================================${NC}"
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

# Warning and confirmation
if [ "$FORCE_MODE" = false ]; then
    print_warning "This script will DESTROY all infrastructure including:"
    echo ""
    echo "  - EKS cluster and all workloads"
    echo "  - VPC and networking resources"
    echo "  - S3 bucket and ALL DATA"
    echo "  - IAM roles and policies"
    echo "  - ECR repositories and container images"
    echo "  - All monitoring data"
    echo "  - Vault and all secrets"
    echo ""
    print_error "THIS ACTION CANNOT BE UNDONE!"
    echo ""

    # Safety confirmation
    read -p "Are you sure you want to destroy ALL infrastructure? Type 'destroy' to confirm: " CONFIRM

    if [ "$CONFIRM" != "destroy" ]; then
        print_error "Teardown cancelled by user"
        echo "To destroy infrastructure, re-run and type 'destroy' when prompted"
        echo "Or use: ./teardown_all.sh --force (skips confirmations)"
        exit 0
    fi

    echo ""
    read -p "Final confirmation - Type 'yes' to proceed: " FINAL_CONFIRM

    if [ "$FINAL_CONFIRM" != "yes" ]; then
        print_error "Teardown cancelled by user"
        exit 0
    fi
else
    print_warning "FORCE MODE: Skipping confirmations and using direct AWS cleanup"
    echo "Press Ctrl+C within 5 seconds to cancel..."
    sleep 5
fi

# Get AWS details
AWS_REGION="${AWS_REGION:-us-east-2}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

if [ -z "$AWS_ACCOUNT_ID" ]; then
    print_error "AWS credentials not configured"
    echo "Please set AWS_PROFILE: export AWS_PROFILE=balto"
    exit 1
fi

print_success "AWS Account ID: $AWS_ACCOUNT_ID"
print_success "AWS Region: $AWS_REGION"

# Step 1: Clean up Kubernetes resources (if cluster exists)
print_section "Step 1: Cleaning Up Kubernetes Resources"

CLUSTER_NAME="${CLUSTER_NAME:-dagster-eks}"

# Check if cluster exists
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &> /dev/null; then
    print_success "EKS cluster found - cleaning up Kubernetes resources"

    # Configure kubectl
    echo "Configuring kubectl..."
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" &> /dev/null || {
        print_warning "Failed to configure kubectl - continuing anyway"
    }

    # Uninstall Helm releases
    echo "Uninstalling Helm releases..."
    helm list --all-namespaces --short 2>/dev/null | while read -r release; do
        namespace=$(helm list --all-namespaces | grep "^$release" | awk '{print $2}')
        if [ -n "$namespace" ]; then
            echo "  Uninstalling $release from $namespace..."
            helm uninstall "$release" -n "$namespace" &> /dev/null || print_warning "Failed to uninstall $release"
        fi
    done
    print_success "Helm releases cleaned up"

    # Delete namespaces (this will cascade delete all resources)
    echo "Deleting namespaces..."
    for ns in data monitoring vault karpenter; do
        if kubectl get namespace "$ns" &> /dev/null; then
            echo "  Deleting namespace: $ns"
            kubectl delete namespace "$ns" --timeout=60s &> /dev/null || print_warning "Failed to delete namespace $ns"
        fi
    done
    print_success "Namespaces deleted"

    # Delete cluster-scoped resources
    echo "Deleting cluster-scoped resources..."
    kubectl delete clusterrolebinding vault-auth-delegator --ignore-not-found=true &> /dev/null || true
    print_success "Cluster-scoped resources cleaned up"

else
    print_warning "EKS cluster not found or not accessible - skipping Kubernetes cleanup"
fi

# Step 2: Clean up orphaned IAM resources
print_section "Step 2: Cleaning Up Orphaned IAM Resources"

echo "Checking for leftover IAM resources..."

# Find all roles starting with "dagster-eks-" (catches timestamp-suffixed roles from Terraform)
echo "Searching for dagster-eks-* roles..."
ORPHANED_ROLES=$(aws iam list-roles --query 'Roles[?starts_with(RoleName, `dagster-eks-`)].RoleName' --output text 2>/dev/null)

if [ -n "$ORPHANED_ROLES" ]; then
    for role in $ORPHANED_ROLES; do
        echo "  Found orphaned role: $role"

        # Detach managed policies
        aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r policy_arn; do
            if [ -n "$policy_arn" ]; then
                echo "    Detaching policy: $policy_arn"
                aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" &> /dev/null || true
            fi
        done

        # Delete inline policies
        aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r policy_name; do
            if [ -n "$policy_name" ]; then
                echo "    Deleting inline policy: $policy_name"
                aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name" &> /dev/null || true
            fi
        done

        # Delete instance profiles attached to the role
        aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r profile_name; do
            if [ -n "$profile_name" ]; then
                echo "    Removing from instance profile: $profile_name"
                aws iam remove-role-from-instance-profile --instance-profile-name "$profile_name" --role-name "$role" &> /dev/null || true
                echo "    Deleting instance profile: $profile_name"
                aws iam delete-instance-profile --instance-profile-name "$profile_name" &> /dev/null || true
            fi
        done

        # Delete the role
        echo "    Deleting role: $role"
        aws iam delete-role --role-name "$role" &> /dev/null && \
            print_success "Deleted orphaned role: $role" || \
            print_warning "Failed to delete role: $role"
    done
else
    echo "  No dagster-eks-* roles found"
fi

# Find all policies starting with "dagster-eks-" (catches all variations)
echo "Searching for dagster-eks-* policies..."
ORPHANED_POLICIES=$(aws iam list-policies --scope Local --query 'Policies[?starts_with(PolicyName, `dagster-eks-`)].PolicyName' --output text 2>/dev/null)

if [ -n "$ORPHANED_POLICIES" ]; then
    for policy_name in $ORPHANED_POLICIES; do
        POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}"
        echo "  Found orphaned policy: $policy_name"

        # Delete all policy versions except the default
        aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r version_id; do
            if [ -n "$version_id" ]; then
                echo "    Deleting policy version: $version_id"
                aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$version_id" &> /dev/null || true
            fi
        done

        # Delete the policy
        echo "    Deleting policy: $policy_name"
        aws iam delete-policy --policy-arn "$POLICY_ARN" &> /dev/null && \
            print_success "Deleted orphaned policy: $policy_name" || \
            print_warning "Failed to delete policy: $policy_name"
    done
else
    echo "  No dagster-eks-* policies found"
fi

print_success "IAM cleanup complete"

# Step 3: Delete AWS resources directly or via Terraform
if [ "$FORCE_MODE" = true ]; then
    print_section "Step 3: Direct AWS Resource Cleanup (Force Mode)"

    # Delete node groups first
    echo "Checking for EKS node groups..."
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &> /dev/null; then
        NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'nodegroups[]' --output text 2>/dev/null)

        if [ -n "$NODEGROUPS" ]; then
            for ng in $NODEGROUPS; do
                echo "  Deleting node group: $ng"
                aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$AWS_REGION" &> /dev/null || true
            done

            echo "  Waiting for node groups to delete (5-10 minutes)..."
            for ng in $NODEGROUPS; do
                aws eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$AWS_REGION" 2>/dev/null || true
            done
            print_success "Node groups deleted"
        else
            print_warning "No node groups found"
        fi

        # Delete EKS cluster
        echo "Deleting EKS cluster..."
        STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")

        if [ "$STATUS" == "ACTIVE" ] || [ "$STATUS" == "FAILED" ]; then
            aws eks delete-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &> /dev/null
            echo "  Waiting for cluster deletion (5-10 minutes)..."
            aws eks wait cluster-deleted --name "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null || true
            print_success "EKS cluster deleted"
        elif [ "$STATUS" == "DELETING" ]; then
            echo "  Cluster already deleting, waiting..."
            aws eks wait cluster-deleted --name "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null || true
            print_success "EKS cluster deleted"
        else
            print_warning "Cluster not found or already deleted"
        fi
    else
        print_warning "EKS cluster not found"
    fi

    # Delete S3 bucket
    echo "Deleting S3 bucket..."
    if aws s3api head-bucket --bucket dagster-weather-products --region "$AWS_REGION" 2>/dev/null; then
        echo "  Emptying bucket..."
        aws s3 rm s3://dagster-weather-products --recursive --region "$AWS_REGION" &> /dev/null || true
        echo "  Deleting bucket..."
        aws s3api delete-bucket --bucket dagster-weather-products --region "$AWS_REGION" &> /dev/null || true
        print_success "S3 bucket deleted"
    else
        print_warning "S3 bucket not found"
    fi

    # Delete VPCs
    echo "Checking for orphaned VPCs..."
    # Find all VPCs with our CIDR range (non-default)
    VPCS=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
        --filters "Name=cidr-block-association.cidr-block,Values=10.42.0.0/16" \
        --query 'Vpcs[?IsDefault==`false`].VpcId' --output text 2>/dev/null)

    if [ -n "$VPCS" ]; then
        echo "  Found $(echo $VPCS | wc -w) VPC(s) to delete"
        for vpc_id in $VPCS; do
            echo ""
            echo "  Deleting VPC: $vpc_id"

            # 0. Terminate EC2 instances in the VPC
            echo "    Checking for EC2 instances..."
            INSTANCES=$(aws ec2 describe-instances --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$vpc_id" "Name=instance-state-name,Values=running,stopped,stopping" \
                --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)

            if [ -n "$INSTANCES" ]; then
                echo "      Found $(echo $INSTANCES | wc -w) instance(s) to terminate"
                for instance_id in $INSTANCES; do
                    INSTANCE_NAME=$(aws ec2 describe-instances --region "$AWS_REGION" \
                        --instance-ids "$instance_id" \
                        --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value' \
                        --output text 2>/dev/null || echo "unnamed")
                    echo "        Terminating instance: $instance_id ($INSTANCE_NAME)"
                    aws ec2 terminate-instances --instance-ids "$instance_id" --region "$AWS_REGION" &> /dev/null || true
                done

                # Wait for instances to terminate
                echo "      Waiting for instances to terminate (2-5 minutes)..."
                for instance_id in $INSTANCES; do
                    aws ec2 wait instance-terminated --instance-ids "$instance_id" --region "$AWS_REGION" 2>/dev/null || {
                        # If wait fails, poll manually
                        for i in {1..60}; do
                            STATE=$(aws ec2 describe-instances --region "$AWS_REGION" \
                                --instance-ids "$instance_id" \
                                --query 'Reservations[0].Instances[0].State.Name' \
                                --output text 2>/dev/null || echo "terminated")
                            if [ "$STATE" == "terminated" ]; then
                                break
                            fi
                            sleep 5
                        done
                    }
                done
                print_success "All instances terminated"
            fi

            # 1. Delete NAT Gateways
            echo "    Checking for NAT Gateways..."
            NAT_GWS=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
                --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available,pending" \
                --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)

            if [ -n "$NAT_GWS" ]; then
                for nat_gw in $NAT_GWS; do
                    echo "      Deleting NAT Gateway: $nat_gw"
                    aws ec2 delete-nat-gateway --nat-gateway-id "$nat_gw" --region "$AWS_REGION" &> /dev/null || true
                done

                # Wait for NAT Gateways to delete (can take 2-3 minutes)
                echo "      Waiting for NAT Gateways to delete (2-3 minutes)..."
                for nat_gw in $NAT_GWS; do
                    # Poll until deleted or failed
                    for i in {1..60}; do
                        STATE=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
                            --nat-gateway-ids "$nat_gw" \
                            --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
                        if [ "$STATE" == "deleted" ] || [ "$STATE" == "failed" ]; then
                            break
                        fi
                        sleep 3
                    done
                done
            fi

            # 2. Release Elastic IPs
            echo "    Checking for Elastic IPs..."
            EIP_ALLOCS=$(aws ec2 describe-addresses --region "$AWS_REGION" \
                --filters "Name=domain,Values=vpc" \
                --query "Addresses[?NetworkInterfaceId==null].AllocationId" --output text 2>/dev/null)

            if [ -n "$EIP_ALLOCS" ]; then
                for alloc_id in $EIP_ALLOCS; do
                    echo "      Releasing EIP: $alloc_id"
                    aws ec2 release-address --allocation-id "$alloc_id" --region "$AWS_REGION" &> /dev/null || true
                done
            fi

            # 3. Detach and delete Internet Gateways
            echo "    Checking for Internet Gateways..."
            IGWS=$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
                --filters "Name=attachment.vpc-id,Values=$vpc_id" \
                --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null)

            if [ -n "$IGWS" ]; then
                for igw in $IGWS; do
                    echo "      Detaching and deleting IGW: $igw"
                    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" --region "$AWS_REGION" &> /dev/null || true
                    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$AWS_REGION" &> /dev/null || true
                done
            fi

            # 4. Delete VPC Endpoints
            echo "    Checking for VPC Endpoints..."
            VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null)

            if [ -n "$VPC_ENDPOINTS" ]; then
                for endpoint in $VPC_ENDPOINTS; do
                    echo "      Deleting VPC Endpoint: $endpoint"
                    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$endpoint" --region "$AWS_REGION" &> /dev/null || true
                done
            fi

            # 5. Delete subnets
            echo "    Checking for subnets..."
            SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --query 'Subnets[].SubnetId' --output text 2>/dev/null)

            if [ -n "$SUBNETS" ]; then
                for subnet in $SUBNETS; do
                    echo "      Deleting subnet: $subnet"
                    aws ec2 delete-subnet --subnet-id "$subnet" --region "$AWS_REGION" &> /dev/null || true
                done
            fi

            # 6. Delete route tables (except main)
            echo "    Checking for route tables..."
            ROUTE_TABLES=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --query 'RouteTables[?Associations[0].Main==`false`].RouteTableId' --output text 2>/dev/null)

            if [ -n "$ROUTE_TABLES" ]; then
                for rtb in $ROUTE_TABLES; do
                    echo "      Deleting route table: $rtb"
                    aws ec2 delete-route-table --route-table-id "$rtb" --region "$AWS_REGION" &> /dev/null || true
                done
            fi

            # 7. Delete security groups (except default)
            echo "    Checking for security groups..."
            SG_IDS=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null)

            if [ -n "$SG_IDS" ]; then
                # First pass: remove all ingress/egress rules to break dependencies
                for sg_id in $SG_IDS; do
                    echo "      Revoking rules for SG: $sg_id"
                    # Revoke all ingress rules
                    aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$sg_id" \
                        --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null | \
                    jq -c '.[]' 2>/dev/null | while read -r rule; do
                        aws ec2 revoke-security-group-ingress --region "$AWS_REGION" --group-id "$sg_id" --ip-permissions "$rule" &> /dev/null || true
                    done
                    # Revoke all egress rules
                    aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$sg_id" \
                        --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null | \
                    jq -c '.[]' 2>/dev/null | while read -r rule; do
                        aws ec2 revoke-security-group-egress --region "$AWS_REGION" --group-id "$sg_id" --ip-permissions "$rule" &> /dev/null || true
                    done
                done

                # Second pass: delete security groups
                for sg_id in $SG_IDS; do
                    echo "      Deleting SG: $sg_id"
                    aws ec2 delete-security-group --group-id "$sg_id" --region "$AWS_REGION" &> /dev/null || true
                done
            fi

            # 8. Delete network ACLs (except default)
            echo "    Checking for network ACLs..."
            NACLS=$(aws ec2 describe-network-acls --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --query 'NetworkAcls[?IsDefault==`false`].NetworkAclId' --output text 2>/dev/null)

            if [ -n "$NACLS" ]; then
                for nacl in $NACLS; do
                    echo "      Deleting network ACL: $nacl"
                    aws ec2 delete-network-acl --network-acl-id "$nacl" --region "$AWS_REGION" &> /dev/null || true
                done
            fi

            # 9. Finally, delete the VPC
            echo "      Deleting VPC: $vpc_id"
            aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$AWS_REGION" &> /dev/null && \
                print_success "VPC $vpc_id deleted" || \
                print_warning "Failed to delete VPC $vpc_id (may have remaining dependencies)"
        done
    else
        print_warning "No orphaned VPCs found"
    fi

    print_success "Direct AWS cleanup completed"

else
    print_section "Step 3: Terraform Infrastructure Destroy"

    cd "$PROJECT_ROOT/opentofu"

    # Check if we have terraform state
    if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
        print_warning "No Terraform state found - infrastructure may already be destroyed"
        print_warning "Use --force flag to force cleanup via AWS CLI"
    else
        echo "Running terraform destroy..."

        # Ensure terraform is initialized
        if [ ! -d ".terraform" ]; then
            echo "Initializing Terraform..."
            tofu init > /dev/null 2>&1 || {
                print_warning "Failed to initialize Terraform"
                print_error "Try running with --force flag: ./teardown_all.sh --force"
                exit 1
            }
        fi

        # Create tfvars file for destroy
        REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        echo "Creating destroy variables..."
        cat > destroy.tfvars <<EOF
dagster_image_repository = "${REGISTRY}/dagster-weather-app"
dagster_image_tag = "latest"
api_image = "${REGISTRY}/weather-products-api:latest"
EOF

        echo "Destroying infrastructure..."
        tofu destroy -var-file=destroy.tfvars -auto-approve || {
            print_error "Terraform destroy encountered errors"
            print_warning "Try running with --force flag: ./teardown_all.sh --force"
            rm -f destroy.tfvars
            exit 1
        }
        rm -f destroy.tfvars
        print_success "Terraform infrastructure destroyed"
    fi
fi

# Step 4: Delete SSH Key Pairs
print_section "Step 4: Deleting SSH Key Pairs"

echo "Checking for SSH key pairs..."
KEY_PAIRS=$(aws ec2 describe-key-pairs --region "$AWS_REGION" --filters "Name=key-name,Values=dagster-eks-*" --query 'KeyPairs[].KeyName' --output text 2>/dev/null)

if [ -n "$KEY_PAIRS" ]; then
    for key_name in $KEY_PAIRS; do
        echo "  Deleting key pair: $key_name"
        aws ec2 delete-key-pair --region "$AWS_REGION" --key-name "$key_name" &> /dev/null && \
            print_success "Deleted key pair: $key_name" || \
            print_warning "Failed to delete key pair: $key_name"
    done
else
    echo "  No dagster-eks-* key pairs found"
fi

print_success "SSH key pairs cleanup complete"

# Step 5: Delete ECR repositories
if [ -n "$AWS_ACCOUNT_ID" ]; then
    print_section "Step 5: Deleting ECR Repositories"

    echo "Deleting dagster-weather-app repository..."
    if aws ecr describe-repositories --repository-names dagster-weather-app --region "$AWS_REGION" &> /dev/null; then
        aws ecr delete-repository \
            --repository-name dagster-weather-app \
            --region "$AWS_REGION" \
            --force \
            &> /dev/null && print_success "Deleted dagster-weather-app repository" || print_warning "Failed to delete dagster-weather-app repository"
    else
        print_warning "dagster-weather-app repository not found"
    fi

    echo "Deleting weather-products-api repository..."
    if aws ecr describe-repositories --repository-names weather-products-api --region "$AWS_REGION" &> /dev/null; then
        aws ecr delete-repository \
            --repository-name weather-products-api \
            --region "$AWS_REGION" \
            --force \
            &> /dev/null && print_success "Deleted weather-products-api repository" || print_warning "Failed to delete weather-products-api repository"
    else
        print_warning "weather-products-api repository not found"
    fi
fi

# Step 6: Clean up local Vault keys
print_section "Step 6: Cleaning Up Local Files"

if [ -d ~/.vault-keys ]; then
    if [ "$FORCE_MODE" = true ]; then
        echo "Force mode: Automatically removing Vault keys..."
        rm -rf ~/.vault-keys
        print_success "Vault keys removed"
        REMOVE_KEYS="yes"
    else
        echo "Removing Vault keys from ~/.vault-keys/..."
        read -p "Remove local Vault keys? (yes/no): " REMOVE_KEYS
        if [ "$REMOVE_KEYS" == "yes" ]; then
            rm -rf ~/.vault-keys
            print_success "Vault keys removed"
        else
            print_warning "Vault keys preserved at ~/.vault-keys/"
        fi
    fi
else
    print_warning "No Vault keys found at ~/.vault-keys/"
    REMOVE_KEYS="no"
fi

# Step 7: Clean up Terraform state and cache
print_section "Step 7: Cleaning Up Terraform Files"

cd "$PROJECT_ROOT/opentofu"

echo "Removing main Terraform state files..."
rm -f terraform.tfstate* 2>/dev/null || true
rm -f tfplan 2>/dev/null || true
rm -f destroy.tfvars 2>/dev/null || true
rm -f .terraform.lock.hcl 2>/dev/null || true
rm -rf .terraform 2>/dev/null || true

echo "Removing vault-config Terraform state files..."
cd "$PROJECT_ROOT/opentofu/vault-config"
rm -f terraform.tfstate* 2>/dev/null || true
rm -f tfplan 2>/dev/null || true
rm -f .terraform.lock.hcl 2>/dev/null || true
rm -rf .terraform 2>/dev/null || true

print_success "Terraform state files removed"

# Step 8: Remove kubectl context
print_section "Step 8: Cleaning Up kubectl Configuration"

if kubectl config get-contexts | grep -q "$CLUSTER_NAME"; then
    echo "Removing kubectl context for $CLUSTER_NAME..."
    kubectl config delete-context "arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}" &> /dev/null || true
    print_success "kubectl context removed"
else
    print_warning "kubectl context not found"
fi

# Step 9: Summary
print_section "Teardown Complete!"

echo ""
print_success "Infrastructure teardown completed successfully!"
echo ""

echo -e "${GREEN}Resources Destroyed:${NC}"
echo "  ✓ EKS cluster"
echo "  ✓ VPCs and all networking resources"
echo "  ✓ NAT Gateways and Elastic IPs"
echo "  ✓ S3 bucket and data"
echo "  ✓ IAM roles and policies"
echo "  ✓ ECR repositories"
echo "  ✓ Terraform state files"
echo ""

if [ "$REMOVE_KEYS" != "yes" ] && [ -d ~/.vault-keys ]; then
    echo -e "${YELLOW}Preserved Files:${NC}"
    echo "  - Vault keys: ~/.vault-keys/"
    echo ""
fi

echo -e "${GREEN}Ready for fresh deployment!${NC}"
echo "Run: ./scripts/deploy_all.sh"
echo ""

print_success "Teardown script completed successfully!"
