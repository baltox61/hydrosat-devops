# Dagster on EKS via **OpenTofu** + **Atlantis** + Audit Hooks

This repository provisions an AWS EKS cluster with OpenTofu, deploys Dagster via Helm,
stores a simple **weather products** dataset in S3, exposes a bastion-only **FastAPI** for `/products`,
and automates CI/CD infra changes with **Atlantis** (configured for OpenTofu).

## Quick Start

```bash
# Pre-reqs: awscli, kubectl, helm, opentofu (tofu), pre-commit
pre-commit install

# 1) Provision infra with OpenTofu
cd opentofu
tofu init
tofu apply -auto-approve -var="openweather_api_key=YOUR_OPENWEATHER_KEY"

# 2) (Optional) Install Atlantis in-cluster (OpenTofu workflow)
helm repo add atlantis https://runatlantis.github.io/helm-charts
kubectl create namespace atlantis || true
kubectl -n atlantis create configmap atlantis-repos --from-file=atlantis/repos.yaml -o yaml --dry-run=client | kubectl apply -f -
helm upgrade --install atlantis atlantis/atlantis -n atlantis -f atlantis/values.yaml

# 3) (If Secret wasn't created by OpenTofu) Apply the OpenWeather secret
kubectl -n data apply -f k8s/secrets/openweather-api-key.yaml

# 4) Access Dagit
# After the LoadBalancer is provisioned, navigate to the Dagit external address.

# 5) Run the weather job from Dagit Launchpad (or CLI)
# (Dagster mounts our repo with weather pipeline; see dagster_jobs/)

# 6) Bastion-only API
kubectl -n data port-forward svc/products-api 8080:8080
curl http://localhost:8080/products
```

## Design
- **OpenTofu** for IaC (no Terraform CLI).
- **EKS** with managed node group across private subnets; public subnets for ELBs.
- **Dagster** via Helm; in-cluster **PostgreSQL** (demo) for metadata.
- **IRSA** to allow Dagster job write access to S3 bucket.
- **Monitoring** via kube-prometheus-stack (Prometheus + Grafana).
- **Atlantis** configured to run `tofu` plan/apply on PRs.
- **Audit**: repo-wide `pre-commit` hooks (fmt, validate, tflint, tfsec, checkov) and `audit/auditchecker.sh`.

## Repo Layout
```
.
├── api/                       # FastAPI to read processed products from S3
├── atlantis/                  # Helm values + repos config
├── dagster_jobs/              # Weather pipeline
├── k8s/                       # Namespace, secrets, API manifests
├── opentofu/                  # All infra
├── audit/                     # Shell audit wrapper
├── .pre-commit-config.yaml
├── atlantis.yaml              # Per-repo config for Atlantis
├── requirements.txt
└── README.md
```

## Security notes
- The API Service is **ClusterIP**; access via bastion `kubectl port-forward` only.
- S3 bucket has public access blocked; IRSA policies scoped to the bucket/prefix.
- For production: consider RDS Postgres, private Ingress + WAF, secrets manager, and dedicated runtime images for user code.

## Testing
- After running the job, verify S3 has `weather-products/YYYY/MM/DD/*.jsonl`.
- Call the API (`/products`) to fetch the latest items.
- Break the job (e.g., bad API key) and confirm failure in Dagit and metrics.
