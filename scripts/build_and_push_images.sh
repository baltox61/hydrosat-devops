#!/bin/bash
# Build and push Docker images to ECR or Docker Hub
# Usage: ./build_and_push_images.sh <registry> <tag>
# Example: ./build_and_push_images.sh myregistry latest

set -e

REGISTRY=${1:-""}
TAG=${2:-"latest"}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Building and Pushing Application Images${NC}"
echo -e "${GREEN}========================================${NC}"

if [ -z "$REGISTRY" ]; then
    echo -e "${RED}Error: Registry not specified${NC}"
    echo "Usage: $0 <registry> [tag]"
    echo ""
    echo "Examples:"
    echo "  ECR: $0 123456789012.dkr.ecr.us-east-2.amazonaws.com latest"
    echo "  Docker Hub: $0 yourusername latest"
    exit 1
fi

# Detect registry type
if [[ $REGISTRY == *".ecr."*".amazonaws.com"* ]]; then
    REGISTRY_TYPE="ecr"
    AWS_REGION=$(echo "$REGISTRY" | sed 's/.*ecr\.\(.*\)\.amazonaws\.com.*/\1/')
    echo -e "${YELLOW}Detected ECR registry in region: $AWS_REGION${NC}"
elif [[ $REGISTRY == *"docker.io"* ]] || [[ $REGISTRY != *"."* ]]; then
    REGISTRY_TYPE="dockerhub"
    echo -e "${YELLOW}Detected Docker Hub registry${NC}"
else
    REGISTRY_TYPE="other"
    echo -e "${YELLOW}Detected custom registry${NC}"
fi

# Login to registry
echo -e "${GREEN}Logging into registry...${NC}"
if [ "$REGISTRY_TYPE" == "ecr" ]; then
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$REGISTRY"
elif [ "$REGISTRY_TYPE" == "dockerhub" ]; then
    echo "Please ensure you're logged in to Docker Hub (docker login)"
    docker login
else
    echo "Please ensure you're logged in to your registry"
fi

# Build Dagster image
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Building Dagster Application Image${NC}"
echo -e "${GREEN}========================================${NC}"
cd "$PROJECT_ROOT/apps/dagster_app"
DAGSTER_IMAGE="${REGISTRY}/dagster-weather-app:${TAG}"
echo "Building: $DAGSTER_IMAGE (linux/amd64)"
docker build --platform linux/amd64 -t "$DAGSTER_IMAGE" .

# Build API image
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Building FastAPI Application Image${NC}"
echo -e "${GREEN}========================================${NC}"
cd "$PROJECT_ROOT/apps"
API_IMAGE="${REGISTRY}/weather-products-api:${TAG}"
echo "Building: $API_IMAGE (linux/amd64)"
docker build --platform linux/amd64 -f Dockerfile.api -t "$API_IMAGE" .

# Push images
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Pushing Images to Registry${NC}"
echo -e "${GREEN}========================================${NC}"

echo "Pushing: $DAGSTER_IMAGE"
docker push "$DAGSTER_IMAGE"

echo "Pushing: $API_IMAGE"
docker push "$API_IMAGE"

# Summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build and Push Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Images published:"
echo "  1. $DAGSTER_IMAGE"
echo "  2. $API_IMAGE"
echo ""
echo "Next steps:"
echo "  1. Update opentofu/dagster.tf:"
echo "     image.repository = \"${REGISTRY}/dagster-weather-app\""
echo "     image.tag = \"${TAG}\""
echo ""
echo "  2. Update opentofu/k8s_api.tf:"
echo "     image = \"${REGISTRY}/weather-products-api:${TAG}\""
echo ""
echo "  3. Apply Terraform:"
echo "     cd opentofu && tofu apply"
