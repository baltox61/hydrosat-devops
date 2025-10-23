# Getting Started

This guide walks you through deploying the infrastructure, testing it, and demonstrating the key features.

---

## Prerequisites

Before starting, ensure you have:

- [ ] AWS CLI configured (`aws configure`)
- [ ] Docker installed and running
- [ ] OpenTofu installed (`tofu --version`)
- [ ] kubectl installed
- [ ] Helm installed
- [ ] OpenWeather API key from https://home.openweathermap.org/api_keys

**Verify AWS credentials:**
```bash
aws sts get-caller-identity
# Should return your account ID and user ARN
```

---

## Part 1: Deployment

### Option 1: Automated Deployment (Recommended)

The fastest way to get everything running:

```bash
# Clone and enter the repository
git clone <repository-url>
cd hydrosat-devops

# Run automated deployment
./scripts/deploy_all.sh
```

**What this does:**
1. ✅ Validates AWS credentials and required tools
2. ✅ Auto-fixes Docker permission issues
3. ✅ Creates ECR repositories
4. ✅ Builds and pushes Docker images
5. ✅ Deploys infrastructure (EKS, Dagster, Vault, monitoring)
6. ✅ Configures kubectl
7. ✅ Initializes and unseals Vault (prompts for OpenWeather API key)
8. ✅ **Runs the pipeline automatically** (populates S3 with weather data)
9. ✅ Verifies deployment and displays access URLs

**Time**: ~20-25 minutes

**Note:** The pipeline runs automatically at the end of deployment, so the API will have data ready to query immediately!

---

### Option 2: Manual Deployment

If you prefer step-by-step control:

#### 1. Build and Push Images

```bash
# Set your AWS details
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION="us-east-2"
export REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Create ECR repositories
aws ecr create-repository --repository-name dagster-weather-app --region $AWS_REGION
aws ecr create-repository --repository-name weather-products-api --region $AWS_REGION

# Build and push images
./scripts/build_and_push_images.sh $REGISTRY latest
```

#### 2. Deploy Infrastructure

```bash
# Create directory for SSH keys
mkdir -p .ssh
chmod 700 .ssh

cd opentofu
tofu init

# Apply with image variables
tofu apply \
  -var="dagster_image_repository=${REGISTRY}/dagster-weather-app" \
  -var="dagster_image_tag=latest" \
  -var="api_image=${REGISTRY}/weather-products-api:latest" \
  -auto-approve
```

**Provisioning time**: ~15-20 minutes

#### 3. Configure kubectl

```bash
aws eks update-kubeconfig --region $AWS_REGION --name dagster-eks
kubectl get nodes  # Verify nodes are Ready
```

#### 4. Initialize Vault

```bash
cd ..
./scripts/vault_init.sh
# Enter your OpenWeather API key when prompted
# Save the root token that's displayed
```

#### 5. Apply Vault Configuration

```bash
cd opentofu
export VAULT_TOKEN="<root-token-from-step-4>"

tofu apply \
  -var="dagster_image_repository=${REGISTRY}/dagster-weather-app" \
  -var="dagster_image_tag=latest" \
  -var="api_image=${REGISTRY}/weather-products-api:latest" \
  -auto-approve
```

#### 6. Run the Pipeline (Populate S3 with Data)

**Important:** Run the pipeline to generate initial weather data, otherwise the API will return empty results.

```bash
# Wait for user-code deployment to be ready
kubectl wait --for=condition=ready pod -l component=user-deployments -n data --timeout=120s

# Get the user-code pod name
POD=$(kubectl get pod -n data -l component=user-deployments -o jsonpath='{.items[0].metadata.name}')

# Run the pipeline
kubectl -n data exec -it $POD -- \
  dagster job execute -m weather_pipeline -j weather_product_job

# Verify data was created in S3
aws s3 ls s3://dagster-weather-products/weather-products/ --recursive
# Should show: weather-products/YYYY/MM/DD/HHMMSS.jsonl
```

---

### Verify Deployment

```bash
# Check all pods are running
kubectl get pods -n data
kubectl get pods -n vault
kubectl get pods -n monitoring

# Get Dagster UI URL
kubectl -n data get svc dagster-dagster-webserver -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Get Grafana URL
kubectl -n monitoring get svc kps-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Expected**: All pods should be in `Running` state.

---

## Part 2: Try It Out

Now that everything is deployed, let's test the key features.

### Quick Reference: Running the Pipeline

**Note:** If you used the **automated deployment** (`./scripts/deploy_all.sh`), the pipeline already ran and S3 has data! You can skip this step and go directly to testing the API.

**If you deployed manually, you need to run the pipeline first to generate weather data:**

**Option 1 - Dagster UI (Recommended):**
```bash
kubectl -n data port-forward deployment/dagster-dagster-webserver 3000:80
# Open http://localhost:3000 → Jobs → weather_product_job → Launchpad → Launch Run
```

**Option 2 - Wait for Automatic Run:**
- Pipeline runs hourly (scheduled via cron: `0 * * * *`)
- Just wait for the top of the next hour and it will run automatically

**Option 3 - Command Line (Advanced):**
```bash
# Get the user-code pod name
POD=$(kubectl get pod -n data -l component=user-deployments -o jsonpath='{.items[0].metadata.name}')

# Execute the job
kubectl -n data exec $POD -- \
  dagster job execute -m weather_pipeline -j weather_product_job
```

**Note:** If the CLI method fails with authentication errors, use the Dagster UI (Option 1) which handles authentication properly.

**Verify it worked:**
```bash
aws s3 ls s3://dagster-weather-products/weather-products/ --recursive
# Should show: weather-products/YYYY/MM/DD/HHMMSS.jsonl
```

---

### 1. Access the API and Test /products Endpoint

**IMPORTANT:** The API returns weather data that was previously collected and stored in S3 by the Dagster pipeline. You must **run the pipeline first** (see step 2 below) before the API will return data.

The API is deployed as a ClusterIP service (internal only) for security. Access it via port-forward:

```bash
# Port forward to API service
kubectl -n data port-forward svc/products-api 8080:8080
```

In another terminal:

```bash
# Health check (works immediately)
curl http://localhost:8080/health
# Response: {"status":"healthy","service":"products-api"}

# List products (returns empty [] until pipeline runs)
curl http://localhost:8080/products
# Response: [] (empty if no data in S3 yet)

# After running the pipeline (step 2), query products:
curl http://localhost:8080/products
curl http://localhost:8080/products?limit=5

# View interactive API docs
open http://localhost:8080/docs
```

**Expected response** (after pipeline runs):
```json
[
  {
    "id": "a1b2c3d4e5f6g7h8",
    "collected_at": "2025-01-15T10:30:00.123456+00:00",
    "location_name": "Luxembourg",
    "lat": 49.6116,
    "lon": 6.1319,
    "temp": 12.5,
    "feels_like": 10.2,
    "humidity": 75,
    "pressure": 1013,
    "wind_speed": 5.5,
    "wind_deg": 180,
    "weather": "overcast clouds",
    "sunrise": 1705308000,
    "sunset": 1705339800,
    "source": "openweathermap_current"
  },
  {
    "id": "h8g7f6e5d4c3b2a1",
    "collected_at": "2025-01-15T10:30:00.123456+00:00",
    "location_name": "Chicago",
    "lat": 41.8781,
    "lon": -87.6298,
    "temp": -2.3,
    "feels_like": -8.1,
    "humidity": 68,
    "pressure": 1020,
    "wind_speed": 8.2,
    "wind_deg": 270,
    "weather": "clear sky",
    "sunrise": 1705320600,
    "sunset": 1705354200,
    "source": "openweathermap_current"
  }
]
```

**Note:** The API fetches data from S3, not directly from the weather API. The cities returned are those configured in the Dagster pipeline (default: **Luxembourg** and **Chicago**).

---

### 2. Run the Weather Pipeline

#### Via Dagster UI:

```bash
# Port-forward to Dagster webserver
kubectl -n data port-forward deployment/dagster-dagster-webserver 3000:80
# Navigate to http://localhost:3000
```

**In Dagster UI:**
1. Go to "Jobs" tab
2. Select `weather_product_job`
3. Go to "Launchpad" tab
3. Click "Launch Run" which should be on the bottom right of the page
4. Monitor progress in "Runs" tab

**What the job does:**
1. Fetches current weather data from OpenWeather API (3 cities)
2. Transforms raw API response into standardized format
3. Uploads JSONL file to S3: `s3://dagster-weather-products/weather-products/YYYY/MM/DD/HHMMSS.jsonl`

#### Via kubectl (CLI):

```bash
# Get the user-code pod name
POD=$(kubectl get pod -n data -l component=user-deployments -o jsonpath='{.items[0].metadata.name}')

# Execute the job
kubectl -n data exec -it $POD -- \
  dagster job execute -m weather_pipeline -j weather_product_job
```

---

### 3. Verify Data in S3

```bash
# List S3 objects
aws s3 ls s3://dagster-weather-products/weather-products/ --recursive

# Download and view a product file
aws s3 cp s3://dagster-weather-products/weather-products/<path-to-file>.jsonl - | jq '.'
```

---

### 4. Access Monitoring Dashboards

#### Grafana:

```bash
# Get Grafana URL
GRAFANA_URL=$(kubectl -n monitoring get svc kps-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana: http://$GRAFANA_URL"
echo "Username: admin"
echo "Password: prom-operator"
```

**Pre-built dashboards:**
- Kubernetes Cluster Monitoring
- Node Exporter Full
- Prometheus Stats

#### Prometheus:

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
# Navigate to http://localhost:9090
```

**Query example metrics:**
- `dagster_job_success_total` - Successful job runs
- `dagster_job_failure_total` - Failed job runs
- `dagster_job_duration_seconds` - Job execution time

---

## Part 3: Demo / Interview Guide

Use this section to showcase the project during interviews or presentations.

### Quick Demo Script (20 minutes)

#### 1. Architecture Overview (3 min)

**Show the high-level architecture:**

```bash
# Show cluster nodes and namespaces
kubectl get nodes
kubectl get namespaces

# Show running pods
kubectl get pods -A | grep -E "vault|data|monitoring"
```

**Key talking points:**
- EKS cluster in private subnets (security-first)
- Vault for centralized secrets management
- Dagster for data orchestration
- Full observability with Prometheus + Grafana
- 100% infrastructure-as-code with OpenTofu

---

#### 2. API & Data Pipeline Demo (5 min)

**Show the API:**

```bash
# Port-forward to API
kubectl -n data port-forward svc/products-api 8080:8080 &

# Query products
curl -s http://localhost:8080/products?limit=3 | jq '.'

# Show that it's ClusterIP (no public access)
kubectl -n data get svc products-api
# TYPE=ClusterIP, EXTERNAL-IP=<none>
```

**Show the pipeline:**

```bash
# Access Dagster UI
kubectl -n data port-forward deployment/dagster-dagster-webserver 3000:80 &
echo "Open: http://localhost:3000"
```

In Dagster UI:
1. Show the assets: `fetch_weather`, `transform_weather`, `upload_to_s3`
2. Click "Materialize All" to run the pipeline
3. Show the lineage graph

**Show S3 output:**

```bash
aws s3 ls s3://dagster-weather-products/weather-products/ --recursive | tail -5
```

---

#### 3. Vault Secrets Management (7 min)

**This is the differentiator - emphasize security!**

```bash
# Port-forward to Vault
kubectl -n vault port-forward svc/vault-ui 8200:8200 &

# Set environment
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="$(cat ~/.vault-keys/root_token)"

# Show Vault status
vault status

# List secrets
vault kv list secret/dagster-eks

# Show Kubernetes authentication
vault auth list
vault read auth/kubernetes/role/dagster-role
```

**Show init container pattern:**

```bash
# Get a Dagster pod
POD=$(kubectl -n data get pods -l app=dagster-user-code -o jsonpath='{.items[0].metadata.name}')

# Show init container logs (secret fetch)
kubectl -n data logs $POD -c vault-init

# Verify secrets are NOT in environment variables
kubectl -n data exec $POD -- env | grep -i key
# (Should not show the API key)

# Show secrets exist as files in memory
kubectl -n data exec $POD -- ls -la /vault/secrets/
```

**Key talking points:**
- Secrets stored in Vault, not Kubernetes Secrets or environment variables
- Pods authenticate using Kubernetes service account JWT
- Init container fetches secrets and writes to shared memory volume
- Application reads secrets from files (more secure than env vars)
- Every secret access is logged (audit trail)

---

#### 4. Infrastructure as Code (3 min)

```bash
# Show clean IaC organization
ls -1 opentofu/*.tf

# Show that everything is version controlled
git log --oneline -5

# Show plan capability (no surprises)
cd opentofu
tofu plan
```

**Key talking points:**
- 100% infrastructure-as-code - no manual kubectl applies
- Using OpenTofu (open-source Terraform fork)
- Modular design: separate files for VPC, EKS, IAM, Helm charts
- All changes are version controlled and peer-reviewed

---

#### 5. Monitoring (2 min)

```bash
# Show Grafana
kubectl -n monitoring port-forward svc/kps-grafana 3000:80 &
echo "Open: http://localhost:3000 (admin/prom-operator)"
```

In Grafana, show:
- Kubernetes Cluster dashboard
- Pod resource usage in `data` namespace

**Key talking points:**
- Pre-built dashboards for cluster and application metrics
- Alerts configured for pipeline failures
- Metrics scraped automatically from all pods

---

### Common Demo Questions & Answers

**Q: How do you handle disaster recovery?**

> A:
> - Vault data backed up via Raft snapshots to S3
> - PostgreSQL backed up to S3 (in production: use RDS with automated backups)
> - OpenTofu state in S3 with versioning enabled
> - All infrastructure recreated via `tofu apply`

**Q: What about scaling?**

> A:
> - EKS node group has auto-scaling (min: 2, max: 5)
> - Karpenter for advanced autoscaling (provisions optimal instance types in 30-60s)
> - Horizontal Pod Autoscaler for Dagster and API
> - S3 scales infinitely

**Q: How do you rotate secrets?**

> A:
> - Update secret in Vault: `vault kv put secret/dagster-eks/openweather-api-key key="NEW_KEY"`
> - Restart pods: `kubectl rollout restart deployment -n data`
> - Init containers fetch new secrets on restart

**Q: Security: what if Vault is compromised?**

> A:
> - Defense in depth:
>   - Network policies restrict Vault access
>   - Kubernetes RBAC limits service account permissions
>   - Vault tokens are short-lived (1 hour TTL)
>   - Audit logs detect anomalies
>   - Production: AWS KMS auto-unseal and seal on breach detection

**Q: What about multi-environment (dev/staging/prod)?**

> A:
> - Separate AWS accounts per environment (recommended)
> - Separate Vault namespaces or clusters
> - OpenTofu workspaces or separate state files
> - Environment-specific variable files

---

### Production Improvements

**Current setup is a demo. For production, I'd add:**

1. **High Availability**: Multi-AZ deployment for all components
2. **RDS**: Managed PostgreSQL instead of in-cluster database
3. **Auto-unseal**: AWS KMS integration for Vault
4. **TLS Everywhere**: mTLS for all service communication
5. **Network Policies**: Restrict pod-to-pod traffic
6. **GitOps**: ArgoCD or FluxCD for continuous deployment
7. **Cost Optimization**: Reserved instances, Spot instances, VPC endpoints
8. **Compliance**: Enable audit logging, encryption at rest, backup policies

---

## Common Issues

### "Missing required variable" error

```bash
# You must provide image variables to tofu apply
tofu apply \
  -var="dagster_image_repository=YOUR_REGISTRY/dagster-weather-app" \
  -var="api_image=YOUR_REGISTRY/weather-products-api:latest"
```

### Images not found / ImagePullBackOff

```bash
# Verify images exist
aws ecr describe-images --repository-name dagster-weather-app --region us-east-2
aws ecr describe-images --repository-name weather-products-api --region us-east-2

# If repositories don't exist, create them
aws ecr create-repository --repository-name dagster-weather-app --region us-east-2
aws ecr create-repository --repository-name weather-products-api --region us-east-2

# Rebuild and push images
./scripts/build_and_push_images.sh $REGISTRY latest
```

### Vault CrashLoopBackOff

**Symptom**: Vault pod keeps restarting with "Liveness probe failed" errors.

**Cause**: Vault's liveness probe was failing when Vault was uninitialized or sealed.

**Fixed in**: `opentofu/vault.tf` line 127 - The liveness probe now returns 204 for sealed/uninitialized states.

If you encounter this on an old deployment:
```bash
# The fix is already in the code, just reapply
cd opentofu
tofu apply -target=helm_release.vault -auto-approve

# Then delete the pod to recreate it
kubectl delete pod -n vault vault-0
```

### Vault is sealed

```bash
# Get unseal keys from ~/.vault-keys/
kubectl -n vault exec vault-0 -- vault operator unseal <key1>
kubectl -n vault exec vault-0 -- vault operator unseal <key2>
kubectl -n vault exec vault-0 -- vault operator unseal <key3>
```

### Dagster user-code pod using wrong image

**Symptom**: Dagster user deployment shows `docker.io/dagster/user-code-example:1.11.13` instead of your custom image.

**Cause**: Helm chart values not applying correctly to deployment.

**Fix**:
```bash
# Directly patch the deployment image
kubectl set image deployment/dagster-dagster-user-deployments-k8s-example-user-code-1 \
  -n data dagster-user-deployments=YOUR_REGISTRY/dagster-weather-app:latest

# Verify it worked
kubectl get pods -n data
# Should show user-code pod as Running (1/1)
```

### EC2 Key Pair "already exists" error after teardown

**Symptom**: After running teardown and re-applying, you get `InvalidKeyPair.Duplicate` error.

**Cause**: Teardown script didn't delete the SSH key pair from AWS.

**Fix**: The teardown script has been updated to automatically delete SSH key pairs. For manual cleanup:
```bash
# Delete the orphaned key pair
aws ec2 delete-key-pair --key-name dagster-eks-bastion-key --region us-east-2

# Then re-apply Terraform
cd opentofu
tofu apply -auto-approve
```

### Missing Vault secrets (API or Dagster failing to start)

**Symptom**: Vault agent init containers fail with "no secret exists" errors.

**Cause**: Vault was initialized but secrets weren't created.

**Fix**:
```bash
# Port-forward to Vault
kubectl -n vault port-forward svc/vault 8200:8200 &

# Set environment
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(cat ~/.vault-keys/vault-init.json | jq -r '.root_token')

# Create required secrets
vault kv put secret/api/rate-limits max_requests_per_minute=100
vault kv put secret/dagster-eks/aws/s3-bucket-name value=dagster-weather-products
vault kv put secret/dagster-eks/openweather-api-key key="YOUR_API_KEY"

# Restart pods to pick up secrets
kubectl rollout restart deployment -n data
```

### API returns empty products

```bash
# Verify S3 has data (run the pipeline first!)
aws s3 ls s3://dagster-weather-products/weather-products/ --recursive

# Check API logs
kubectl -n data logs deployment/products-api
```

---

## Cleanup

### Automated Cleanup (Recommended)

```bash
# Normal mode (uses Terraform destroy)
./scripts/teardown_all.sh

# Force mode (bypasses Terraform, uses direct AWS cleanup)
./scripts/teardown_all.sh --force
```

### Manual Cleanup

```bash
cd opentofu
tofu destroy -auto-approve
```

**Warning**: This deletes all infrastructure and data.

---

## Next Steps

- Review detailed architecture in **README.md**
- Learn about day-2 operations in **OPERATIONS.md**
- Explore architecture diagrams in **docs/diagrams.md**
- Review app development guide in **apps/README.md**

---

## Support

For detailed troubleshooting, see **OPERATIONS.md**

For architectural decisions, see **README.md**
