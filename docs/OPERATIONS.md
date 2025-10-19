# Operations Guide

This guide covers day-2 operations including Vault management, testing, monitoring, and troubleshooting.

---

## Table of Contents

- [Vault Operations](#vault-operations)
- [Testing](#testing)
- [Monitoring & Alerting](#monitoring--alerting)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)

---

## Vault Operations

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                         EKS Cluster                         │
│                                                             │
│  ┌──────────────┐      ┌──────────────┐    ┌──────────────┐ │
│  │   Vault      │◄─────┤  Dagster Pod │    │   API Pod    │ │
│  │  (namespace) │      │              │    │              │ │
│  │              │      │ Init:        │    │ Init:        │ │
│  │ - Raft       │      │ 1. Auth w/   │    │ 1. Auth w/   │ │
│  │   Storage    │      │    SA token  │    │    SA token  │ │
│  │ - K8s Auth   │      │ 2. Fetch     │    │ 2. Fetch     │ │
│  │ - Policies   │      │    secrets   │    │    secrets   │ │
│  └──────────────┘      │ 3. Write to  │    │ 3. Write to  │ │
│                        │    /app/.env │    │    /app/.env │ │
└─────────────────────────────────────────────────────────────┘
```

### Checking Vault Status

```bash
# Check if Vault is sealed
kubectl -n vault exec vault-0 -- vault status

# Expected output:
# Sealed: false
# Total Shares: 5
# Threshold: 3
# Initialized: true
```

### Unsealing Vault

If Vault pod restarts, it will be sealed. Unseal with 3 of 5 keys:

```bash
# Check status
kubectl -n vault exec vault-0 -- vault status
# Output: Sealed: true

# Unseal with 3 of 5 keys (keys saved in ~/.vault-keys/)
kubectl -n vault exec vault-0 -- vault operator unseal <key1>
kubectl -n vault exec vault-0 -- vault operator unseal <key2>
kubectl -n vault exec vault-0 -- vault operator unseal <key3>

# Verify
kubectl -n vault exec vault-0 -- vault status
# Output: Sealed: false
```

**Quick unseal script:**
```bash
./scripts/vault_init.sh
# Choose option to unseal only
```

---

### Managing Secrets

#### Access Vault

```bash
# Port-forward to Vault
kubectl -n vault port-forward svc/vault-ui 8200:8200 &

# Set environment
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="<your-root-token>"  # From ~/.vault-keys/root_token
```

#### Common Secret Operations

```bash
# List all secrets
vault kv list secret/dagster-eks

# Read a secret
vault kv get secret/dagster-eks/openweather-api-key

# Add/update a secret
vault kv put secret/dagster-eks/openweather-api-key key="new-api-key-value"

# Delete a secret
vault kv delete secret/dagster-eks/openweather-api-key

# View secret history (versioned secrets)
vault kv get -version=2 secret/dagster-eks/openweather-api-key
```

---

### Secret Organization

Secrets are organized by scope:

```
secret/
├── dagster-eks/              # Cluster-scoped secrets
│   ├── openweather-api-key   # External API keys
│   ├── postgres/
│   │   └── dagster-db-password
│   └── aws/
│       └── s3-bucket-name
├── dagster/                  # Dagster app-specific
│   └── pipeline-config
└── api/                      # API app-specific
    └── rate-limits
```

All secrets are defined in `opentofu/vault-secrets.json`.

---

### Rotating Secrets

```bash
# 1. Update secret in Vault
vault kv put secret/dagster-eks/openweather-api-key key="NEW_KEY"

# 2. Restart pods to pick up new secret
kubectl -n data rollout restart deployment dagster-user-code
kubectl -n data rollout restart deployment products-api

# 3. Verify pods started successfully
kubectl -n data get pods
kubectl -n data logs <pod-name> -c vault-agent
```

---

### Vault Policies

Two policies control access:

#### dagster-app (Dagster user-code pods)
- Read-only access to:
  - `secret/dagster/*`
  - `secret/dagster-eks/openweather-api-key`
  - `secret/dagster-eks/postgres/*`
  - `secret/dagster-eks/aws/*`

#### api-app (API pods)
- Read-only access to:
  - `secret/api/*`
  - `secret/dagster-eks/postgres/*`
  - `secret/dagster-eks/aws/*`

**View policies:**
```bash
vault policy list
vault policy read dagster-app
vault policy read api-app
```

---

### Debugging Secret Access

If pods fail to start due to Vault issues:

```bash
# Check init container logs
kubectl -n data logs <pod-name> -c vault-agent

# Common issues:
# 1. "connection refused" → Vault is sealed or not running
# 2. "permission denied" → Vault policy doesn't allow access
# 3. "secret not found" → Secret path doesn't exist in Vault

# Verify service account exists
kubectl -n data get sa dagster-user-code

# Check Vault role binding
vault read auth/kubernetes/role/dagster-role

# Verify policy allows access
vault policy read dagster-app
```

---

## Testing

### Automated Testing

#### Test Application Code Locally

```bash
./scripts/test_apps_locally.sh
```

**Tests performed (8 total):**
- Python syntax validation
- Import checks for Dagster and API
- FastAPI structure validation
- Dagster job definition checks
- Secret reading helper functions
- Dagster CLI validation

#### Test Infrastructure End-to-End

```bash
# After infrastructure is provisioned
./scripts/test_e2e.sh
```

**Tests performed (15 total):**
- Kubernetes cluster connectivity
- Namespace existence (data, vault, monitoring)
- Node readiness
- Vault status and unseal state
- Dagster pod health
- API pod health
- Secret injection verification
- S3 bucket access
- IRSA configuration
- Prometheus metrics scraping
- Grafana accessibility

---

### Manual Testing

#### 1. Test Dagster Pipeline

```bash
# Trigger job via Dagster UI
kubectl -n data port-forward svc/dagster-dagster-webserver 3000:80
# Navigate to http://localhost:3000 and trigger the job

# Or via kubectl
kubectl -n data exec -it deployment/dagster-dagster-webserver -- \
  dagster job execute -m weather_pipeline -j weather_product_job

# Verify in Dagit UI that run succeeds
# Check S3 for output files
aws s3 ls s3://dagster-weather-products/weather-products/ --recursive
```

#### 2. Test API

```bash
# Port forward to API
kubectl -n data port-forward svc/products-api 8080:8080

# Query products
curl http://localhost:8080/products?limit=5

# Verify returns weather data from S3
```

#### 3. Test Vault Integration

```bash
# Verify Vault pod has secrets
POD=$(kubectl -n data get pod -l app=dagster-user-code -o jsonpath='{.items[0].metadata.name}')

# Check init container logs
kubectl -n data logs $POD -c vault-agent
# Should show: "Vault agent successfully authenticated"

# Verify secrets exist in pod
kubectl -n data exec $POD -- ls -la /app/.env
kubectl -n data exec $POD -- cat /app/.env
```

#### 4. Test IRSA (IAM Roles for Service Accounts)

```bash
# Verify Dagster pod has S3 write access
POD=$(kubectl -n data get pod -l app=dagster-user-code -o jsonpath='{.items[0].metadata.name}')

kubectl -n data exec $POD -- env | grep AWS
# Should show: AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE

kubectl -n data exec $POD -- aws sts get-caller-identity
# Should show the IRSA role ARN

# Test S3 write permission
kubectl -n data exec $POD -- aws s3 ls s3://dagster-weather-products/
```

#### 5. Test Karpenter Autoscaling

```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Deploy a resource-intensive workload
kubectl run stress --image=polinux/stress -- \
  --cpu 4 --timeout 300s

# Watch Karpenter provision a new node (30-60 seconds)
kubectl get nodes -w

# Check which instance type Karpenter selected
kubectl get node -o json | jq -r '.items[] | .metadata.labels["node.kubernetes.io/instance-type"]'

# Delete workload
kubectl delete pod stress

# Watch Karpenter terminate unused node (~30 seconds)
kubectl get nodes -w
```

---

### Expected Test Results

✅ **Infrastructure**: All nodes are Ready, all pods are Running
✅ **Dagster**: Job runs successfully, data written to S3
✅ **API**: Returns products from S3, only accessible via port-forward
✅ **Monitoring**: Prometheus scrapes Dagster metrics, Grafana dashboards load
✅ **Karpenter**: Provisions optimal instance types in 30-60 seconds

---

## Monitoring & Alerting

### Architecture

```
┌─────────────────┐
│  Dagster Pods   │─────▶ Expose metrics on /metrics
└─────────────────┘
         │
         │ scrape (30s interval)
         ▼
┌─────────────────┐
│   Prometheus    │─────▶ Store time-series data
└─────────────────┘       Evaluate alert rules
         │
         ├────────────────▶ Send to Grafana (dashboards)
         │
         └────────────────▶ Send to AlertManager (alerts)
                                     │
                                     ▼
                            ┌─────────────────┐
                            │  Slack/Email/   │
                            │   PagerDuty     │
                            └─────────────────┘
```

### Accessing Monitoring UIs

#### Prometheus

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
# Navigate to http://localhost:9090
```

**Query example metrics:**
- `dagster_job_success_total` - Total successful job runs
- `dagster_job_failure_total` - Total failed job runs
- `dagster_job_duration_seconds` - Job execution time
- `dagster_daemon_heartbeat` - Daemon health check

#### Grafana

```bash
kubectl -n monitoring get svc kps-grafana
# Navigate to http://<EXTERNAL-IP>
# Default credentials: admin / prom-operator
```

**Pre-built dashboards:**
- Kubernetes Cluster Monitoring
- Node Exporter Full
- Prometheus Stats

#### AlertManager

```bash
kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093
# Navigate to http://localhost:9093
```

---

### Alert Rules

#### DagsterJobFailed (Critical)
- **Condition**: Any job failure in last 5 minutes
- **Duration**: Alerts after 1 minute
- **Action**: Notify on-call engineer via Slack/email
- **Runbook**: Check Dagit UI for error details, review pod logs

#### DagsterDaemonDown (Warning)
- **Condition**: Dagster daemon is down
- **Duration**: Alerts after 5 minutes
- **Action**: Notify platform team
- **Runbook**: Check pod status, review logs, verify database connectivity

---

### Testing Alerts

```bash
# Simulate job failure (invalid API key)
kubectl -n data set env deployment/dagster-user-code-weather-pipeline \
  OPENWEATHER_API_KEY_FILE=/vault/secrets/INVALID

# Trigger job in Dagit (will fail)

# Check AlertManager
kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093
# Navigate to http://localhost:9093/#/alerts
# Should see "DagsterJobFailed" alert after ~1 minute

# Restore correct configuration
kubectl -n data rollout restart deployment/dagster-user-code-weather-pipeline
```

---

### Alert Configuration

#### Slack Integration (Optional)

```bash
# Add Slack webhook URL when applying infrastructure
tofu apply \
  -var="slack_webhook_url=https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

Alerts will be sent to `#dagster-alerts` channel.

#### Email Integration

Edit `opentofu/monitoring.tf` to add email receiver:

```hcl
receivers = [
  {
    name = "email-notifications"
    email_configs = [{
      to = "oncall@company.com"
      from = "alerts@company.com"
      smarthost = "smtp.gmail.com:587"
    }]
  }
]
```

---

## Troubleshooting

### Common Issues

#### Nodes Not Ready

```bash
# Check node status
kubectl describe node <node-name>

# Check node logs
aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=dagster-eks"

# Common causes:
# - Security group rules blocking communication
# - IAM role missing policies
# - Insufficient capacity in AZ
```

#### Vault Sealed After Restart

```bash
# Check status
kubectl -n vault exec vault-0 -- vault status

# Unseal (need 3 of 5 keys from ~/.vault-keys/)
kubectl -n vault exec vault-0 -- vault operator unseal <key1>
kubectl -n vault exec vault-0 -- vault operator unseal <key2>
kubectl -n vault exec vault-0 -- vault operator unseal <key3>
```

#### Pods Can't Fetch Secrets from Vault

```bash
# Check init container logs
kubectl -n data logs <pod-name> -c vault-agent

# Common causes:
# - Vault is sealed
# - Service account not bound to Vault role
# - Vault policy doesn't allow access
# - Network issues with vault.vault.svc.cluster.local:8200

# Verify Vault role
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="<root-token>"
vault read auth/kubernetes/role/dagster-role
```

#### Dagster Job Fails with "Access Denied" to S3

```bash
# Verify IRSA role annotation
kubectl -n data get sa dagster-user-code -o yaml | grep eks.amazonaws.com/role-arn

# Check pod has AWS credentials
kubectl -n data exec -it <dagster-pod> -- env | grep AWS

# Test S3 access from pod
kubectl -n data exec -it <dagster-pod> -- \
  aws s3 ls s3://dagster-weather-products/
```

#### API Returns Empty Products `[]`

**Cause:** The API returns data from S3. If S3 is empty, the API returns `[]`.

**Solution:**

```bash
# 1. Check if S3 has data
aws s3 ls s3://dagster-weather-products/weather-products/ --recursive

# If empty, run the Dagster pipeline first:
kubectl -n data port-forward deployment/dagster-dagster-webserver 3000:80
# Go to http://localhost:3000, click "Jobs" → "weather_product_job" → "Launchpad" → "Launch Run"

# Or via CLI (from the user-code pod):
POD=$(kubectl get pod -n data -l component=user-deployments -o jsonpath='{.items[0].metadata.name}')
kubectl -n data exec -it $POD -- \
  dagster job execute -m weather_pipeline -j weather_product_job

# 2. Wait for job to complete (~30 seconds)

# 3. Verify S3 now has data
aws s3 ls s3://dagster-weather-products/weather-products/ --recursive

# 4. Test API again
curl http://localhost:8080/products
# Should now return weather data for Luxembourg and Chicago

# If still empty, check API logs
kubectl -n data logs deployment/products-api

# Verify IRSA for API pod (needs S3 read access)
kubectl -n data get sa products-api -o yaml | grep eks.amazonaws.com/role-arn
```

#### AlertManager Not Sending Alerts

```bash
# Check AlertManager configuration
kubectl -n monitoring get secret alertmanager-kps-alertmanager -o yaml

# Test Slack webhook manually
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"Test alert"}' \
  YOUR_SLACK_WEBHOOK_URL

# Check AlertManager logs
kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager
```

#### Pods Stuck in ImagePullBackOff

```bash
# Check pod events
kubectl -n data describe pod <pod-name>

# Verify images exist in ECR
aws ecr describe-images --repository-name dagster-weather-app --region us-east-2
aws ecr describe-images --repository-name weather-products-api --region us-east-2

# Rebuild and push images if needed
./scripts/build_and_push_images.sh <registry> latest
```

#### OpenTofu Apply Fails

```bash
# Enable debug logging
export TF_LOG=DEBUG
export TF_LOG_PATH=./terraform-debug.log

tofu apply

# Check the log file for detailed errors
tail -100 terraform-debug.log
```

---

### Checking Resource Status

```bash
# Quick health check of all components
kubectl get pods -A | grep -v Running

# Check specific namespaces
kubectl get all -n data
kubectl get all -n vault
kubectl get all -n monitoring

# Check recent events
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# Check node resource usage
kubectl top nodes
kubectl top pods -A
```

---

## Maintenance

### Backing Up Vault Data

```bash
# Create Raft snapshot
kubectl -n vault exec vault-0 -- vault operator raft snapshot save /tmp/vault-snapshot.snap

# Copy snapshot to local machine
kubectl -n vault cp vault-0:/tmp/vault-snapshot.snap ./vault-snapshot-$(date +%Y%m%d).snap

# Upload to S3 for safekeeping
aws s3 cp ./vault-snapshot-$(date +%Y%m%d).snap s3://your-backup-bucket/vault-snapshots/
```

### Restoring Vault from Backup

```bash
# Copy snapshot to Vault pod
kubectl -n vault cp ./vault-snapshot.snap vault-0:/tmp/vault-snapshot.snap

# Restore snapshot
kubectl -n vault exec vault-0 -- vault operator raft snapshot restore /tmp/vault-snapshot.snap
```

### Updating Application Images

```bash
# Build new images
./scripts/build_and_push_images.sh <registry> v2.0

# Update OpenTofu variables
cd opentofu
tofu apply \
  -var="dagster_image_tag=v2.0" \
  -var="api_image=<registry>/weather-products-api:v2.0"

# Or manually update deployments
kubectl -n data set image deployment/dagster-user-code \
  dagster-user-code=<registry>/dagster-weather-app:v2.0

kubectl -n data set image deployment/products-api \
  api=<registry>/weather-products-api:v2.0
```

### Cleaning Up Old Resources

```bash
# Remove completed pods
kubectl delete pods -n data --field-selector=status.phase==Succeeded

# Clean up old ReplicaSets
kubectl delete replicaset -n data $(kubectl get rs -n data -o jsonpath='{.items[?(@.spec.replicas==0)].metadata.name}')

# Prune unused Docker images from nodes (SSH to node)
docker image prune -a -f
```

### Monitoring Disk Usage

```bash
# Check PVC usage
kubectl get pvc -A

# Check node disk usage
kubectl get nodes -o json | \
  jq '.items[] | {name:.metadata.name, disk:.status.allocatable."ephemeral-storage"}'

# Check specific PVC usage (requires metrics-server)
kubectl top pvc -A
```

---

## Production Recommendations

For a production deployment, implement:

### High Availability
- Multi-AZ Vault deployment (3-5 replicas)
- RDS PostgreSQL with Multi-AZ failover
- Multiple NAT Gateways (one per AZ)
- Cross-region backup replication

### Security Enhancements
- AWS KMS auto-unseal for Vault
- TLS/mTLS everywhere (cert-manager)
- Network policies for pod-to-pod traffic
- Pod Security Policies/Pod Security Admission
- VPC endpoints for AWS services (avoid NAT)
- AWS GuardDuty for threat detection
- VPC Flow Logs to S3/CloudWatch

### Monitoring & Observability
- Longer Prometheus retention (weeks/months)
- Remote storage (S3/Thanos) for metrics
- Distributed tracing (Jaeger/Tempo)
- Log aggregation (ELK/Loki)
- Custom SLI/SLO dashboards

### Automation
- GitOps with ArgoCD or FluxCD
- Automated backup schedules
- Automated secret rotation
- Chaos engineering (Chaos Mesh)

### Cost Optimization
- Reserved Instances for baseline capacity
- Spot Instances for batch workloads
- S3 lifecycle policies (Standard → IA → Glacier)
- Right-sizing recommendations from Kubecost

---

## Support

For deployment instructions, see **GETTING_STARTED.md**

For architectural overview, see **README.md**

For app development, see **apps/README.md**
