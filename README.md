# Dagster Data Platform on Kubernetes

A production-ready AWS EKS cluster with Dagster for data orchestration, demonstrating infrastructure-as-code, secrets management with HashiCorp Vault, and comprehensive monitoring.

---

## Quick Links

- **🚀 Get Started:** [DEMO_GUIDE.md](DEMO_GUIDE.md) - Prerequisites, deployment, and demo walkthrough
- **📸 Working Examples:** [docs/WORKING_EXAMPLES.md](docs/WORKING_EXAMPLES.md) - Live command examples and screenshots showing the platform in action
- **📚 Detailed Setup:** [docs/SETUP.md](docs/SETUP.md) - Complete setup guide with architecture details

---

## Overview

### What This Project Does

1. **Provisions AWS Infrastructure** - EKS cluster with VPC, subnets, security groups, IAM roles
2. **Deploys Dagster** - Data orchestration platform for weather data pipeline
3. **Implements Secure Secrets Management** - HashiCorp Vault with Kubernetes authentication
4. **Exposes REST API** - FastAPI service for querying processed weather data
5. **Monitors Everything** - Prometheus + Grafana + AlertManager for observability
6. **Automates Everything** - 100% infrastructure as code with OpenTofu

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         AWS Cloud                           │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  VPC (Multi-AZ)                                      │   │
│  │                                                      │   │
│  │  ┌─────────────────┐    ┌─────────────────┐          │   │
│  │  │ Public Subnets  │    │ Public Subnets  │          │   │
│  │  │ (AZ A)          │    │ (AZ B)          │          │   │
│  │  │ - LoadBalancers │    │ - NAT Gateway   │          │   │
│  │  └────────┬────────┘    └────────┬────────┘          │   │
│  │           │                      │                   │   │
│  │  ┌────────┴──────────────────────┴────────┐          │   │
│  │  │         Internet Gateway               │          │   │
│  │  └────────────────────────────────────────┘          │   │
│  │                                                      │   │
│  │  ┌─────────────────┐    ┌─────────────────┐          │   │
│  │  │ Private Subnets │    │ Private Subnets │          │   │
│  │  │ (AZ A)          │    │ (AZ B)          │          │   │
│  │  │                 │    │                 │          │   │
│  │  │  EKS Nodes      │    │  EKS Nodes      │          │   │
│  │  └─────────────────┘    └─────────────────┘          │   │
│  │                                                      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  S3 Bucket: Weather Products                         │   │
│  │  - Date-partitioned storage (YYYY/MM/DD)             │   │
│  │  - 7-day lifecycle policy                            │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**→ See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture information**

---

## Key Components

### Infrastructure
- **AWS EKS** - Kubernetes 1.33 with managed node groups across 2 AZs, I went with 1.33 since I have not read over docs for 1.34 upgrade just yet
- **VPC** - Multi-AZ with public/private subnets, NAT Gateway, Internet Gateway
- **Karpenter** - Advanced cluster autoscaler with dynamic instance selection
- **S3** - Object storage for weather data products with lifecycle policies

### Applications
- **Dagster** - Data orchestration platform running weather data pipeline
- **FastAPI** - REST API for querying processed weather products
- **PostgreSQL** - In-cluster database for Dagster metadata (demo setup)

### Security & Secrets
- **HashiCorp Vault** - Centralized secrets management with Kubernetes authentication
- **IRSA** - IAM Roles for Service Accounts (no static credentials)
- **Init Container Pattern** - Secrets injected at runtime, stored in memory only

### Monitoring
- **Prometheus** - Metrics collection and alerting
- **Grafana** - Visualization and dashboards
- **AlertManager** - Alert routing and notifications

---

## Technology Decisions

### Why Vault for Secrets Management?

- No secrets in Terraform variables, state files, or Git
- Runtime secret injection fetched at pod startup via init containers
- Kubernetes pods authenticate using service account JWT tokens
- Centralized management and single source of truth for all secrets
- Every secret access is logged and versioned

### Why Prometheus + Grafana?

- Widely used monitoring stack for Kubernetes, a lot of support and documentation
- Native Kubernetes integration, automatically discovers pods and services
- Dagster exposes Prometheus metrics out-of-the-box
- PromQL for complex metric analysis
- open-source, lots of community support

### Why In-Cluster PostgreSQL?

**For Demo:**
- Single-command deployment, no external dependencies
- Fast provisioning (up in minutes)
- Cost effective (no RDS charges)

---

### Vault Init Container Pattern

**How It Works:**
1. Init container runs before application starts
2. Authenticates to Vault using Kubernetes service account
3. Fetches secrets and writes to shared memory volume
4. Application reads secrets from `/app/.env` file (not environment variables)
5. Secrets exist only in pod memory, cleared when pod terminates

**Benefits:**
- Secrets not visible in `kubectl describe pod`
- Cannot be leaked via environment variable dumps
- Automatic authentication (no passwords)
- Audit trail of every secret access
- Secrets can be versioned
- Secrets can be rotated without rebuilding images
- Least privilege via Vault policies
- Allows for a more automated process

**→ See [docs/OPERATIONS.md](docs/OPERATIONS.md#vault-operations) for Vault management details**

---

## Data Pipeline

### Weather Data Pipeline

**Default Cities:** Luxembourg, Chicago (configurable in `weather_pipeline.py`)

**Pipeline Steps:**
1. **fetch_weather** - Fetches current weather data from OpenWeather API for configured cities
2. **transform_weather** - Processes and enriches raw API response
3. **upload_to_s3** - Stores processed data as JSONL in S3 with date partitioning

**Output:**
- S3 path: `s3://dagster-weather-products/weather-products/YYYY/MM/DD/HHMMSS.jsonl`
- Format: JSONL (JSON Lines) for efficient streaming
- Lifecycle: 7-day retention for demo (configurable)
- Schedule: Runs hourly (or on-demand via Dagster UI)

### REST API

**How it works:** The API serves weather data that was previously collected and stored in S3 by the Dagster pipeline. It does NOT fetch live weather data directly.

**Endpoints:**
- `GET /products?limit=N` - Retrieve latest N weather product files from S3
- `GET /health` - Health check endpoint

**Important:** Run the Dagster pipeline first to populate S3, otherwise the API returns an empty array `[]`.

**Security:**
- ClusterIP service (no public access)
- Accessible only via kubectl port-forward or bastion host
- IRSA for S3 read access (no static credentials)

**→ See [DEMO_GUIDE.md](DEMO_GUIDE.md) for API testing instructions**

---

## Monitoring & Alerting

### Grafana Dashboards

Three custom dashboards optimized for demos and interviews:

**1. Kubernetes Cluster Overview** - Essential cluster metrics (nodes, pods, CPU, memory)
**2. Weather Products API** - API performance and health (request rates, latency, errors)
**3. Dagster Pipeline** - Job success rates, durations, failures, and resource usage

Access at: http://grafana.dagster.local (admin/prom-operator)

### Key Metrics

**Dagster Metrics:**
- Job success/failure rates and duration
- Step-level execution metrics
- Daemon heartbeat and active runs
- Demo job failure rate (for testing alerts)

**Kubernetes Metrics:**
- Pod CPU/Memory usage by namespace
- Node resource utilization
- Pod status and restart counts

### Alert Rules

**Critical Alerts:**
- **DagsterJobFailed** - Alerts after any job failure
- **S3UploadFailures** - S3 upload step fails

**Warning Alerts:**
- **DagsterDaemonDown** - Daemon down for >5 minutes
- **WeatherPipelineStale** - No successful runs in 2 hours
- **DemoJobFailed** - Demo job failed (for testing alerts)

**→ See [docs/MONITORING.md](docs/MONITORING.md) for full monitoring setup and alert configuration**

---

## Project Structure

```
.
├── opentofu/                      # Infrastructure as Code
│   ├── vpc.tf                     # VPC, subnets, NAT Gateway
│   ├── eks.tf                     # EKS cluster and node groups
│   ├── iam.tf                     # IAM roles and IRSA
│   ├── s3.tf                      # S3 bucket for products
│   ├── karpenter.tf               # Karpenter autoscaler
│   ├── dagster.tf                 # Dagster Helm deployment
│   ├── vault.tf                   # Vault Helm deployment
│   ├── vault_agent.tf             # Vault agent configurations
│   ├── monitoring.tf              # Prometheus + Grafana + AlertManager
│   └── k8s_api.tf                 # Products API deployment
│
├── apps/                          # Application code
│   ├── api.py                     # FastAPI for product access
│   ├── Dockerfile.api             # Docker image for FastAPI
│   └── dagster_app/               # Dagster weather pipeline
│       ├── weather_pipeline.py    # Pipeline implementation
│       └── Dockerfile             # Docker image for Dagster
│
├── scripts/                       # Operational scripts
│   ├── deploy_all.sh              # Automated deployment
│   ├── teardown_all.sh            # Automated cleanup
│   ├── vault_init.sh              # Initialize and unseal Vault
│   └── setup_dns_aliases.sh       # DNS alias configuration
│
├── docs/                          # Documentation
│   ├── SETUP.md                   # Detailed setup guide
│   ├── OPERATIONS.md              # Vault, monitoring, troubleshooting
│   ├── MONITORING.md              # Monitoring and alerting details
│   └── ARCHITECTURE.md            # Architecture decisions and diagrams
│
├── DEMO_GUIDE.md                  # Interview/demo walkthrough
├── apps/README.md                 # App development guide
└── README.md                      # This file
```

---

## Production Recommendations

This is a demo setup. For production, implement:

### High Availability
- **Multi-AZ Vault** deployment (3-5 replicas) with AWS KMS auto-unseal
- **RDS PostgreSQL** with Multi-AZ, automated backups, and point-in-time recovery
- **Multiple NAT Gateways** (one per AZ) for redundancy
- **Cross-region backup** replication

### Security
- **TLS/mTLS everywhere** using cert-manager for certificate management
- **Network Policies** to restrict pod-to-pod traffic
- **Pod Security Admission** for workload hardening
- **VPC Endpoints** for AWS services (avoid NAT costs and improve security)
- **AWS GuardDuty** for threat detection
- **VPC Flow Logs** to S3/CloudWatch for audit trail

### Monitoring & Observability
- **Longer Prometheus retention** (weeks/months) with remote storage (S3/Thanos)
- **Custom SLI/SLO dashboards** for business metrics based on KPIs

### Automation
- **Automated backup schedules** for Vault and PostgreSQL
- **Automated secret rotation** policies
- **Chaos engineering** with Chaos Mesh for resilience testing

---

## Documentation

- **[GETTING_STARTED.md](GETTING_STARTED.md)** - Deployment, testing, and demo instructions
- **[OPERATIONS.md](OPERATIONS.md)** - Vault operations, testing, monitoring, troubleshooting
- **[apps/README.md](apps/README.md)** - Application development guide
- **[docs/diagrams.md](docs/diagrams.md)** - Architecture diagrams

---

## Future Improvements

This project demonstrates a production-ready foundation, but there are several enhancements that would be valuable in a real-world production environment:

### CI/CD Automation with Atlantis

**What is Atlantis?**
Atlantis is a self-hosted application that automates OpenTofu/Terraform workflows via pull requests. It brings GitOps principles to infrastructure management.

**Why Atlantis would be valuable:**

1. **GitOps Workflow**
   - Automatic `tofu plan` when infrastructure PRs are opened
   - Plan results posted as PR comments for team review
   - Apply changes via PR comments (`atlantis apply`)
   - All infrastructure changes tracked in git history

2. **Safety & Collaboration**
   - Human review before any infrastructure changes
   - Team visibility into proposed changes
   - Prevents direct production access (no local applies)
   - State locking prevents concurrent modifications

3. **Automation**
   - Eliminates manual `tofu plan`/`apply` commands
   - Consistent deployment process across team
   - Integration with GitHub status checks
   - Can block merges if plan fails

**How it would work:**
```
Developer              GitHub                 Atlantis (in EKS)       AWS
    |                     |                          |                 |
    |--1. Push PR-------->|                          |                 |
    |                     |--2. Webhook------------->|                 |
    |                     |                          |                 |
    |                     |                    3. tofu plan            |
    |                     |<--4. Post plan comment---|                 |
    |                     |                          |                 |
    |--5. Review & approve|                          |                 |
    |--6. Comment---------  "atlantis apply"         |                 |
    |   "atlantis apply"  |--7. Webhook------------->|                 |
    |                     |                          |                 |
    |                     |                   8. tofu apply            |
    |                     |                          |--9. Provision-->|
    |                     |<-10. Post result---------|                 |
    |--11. Merge PR------>|                          |                 |
```

**Implementation:**
The infrastructure already includes Vault policies and IRSA roles. To enable Atlantis:
- Uncomment Atlantis resources in `opentofu/` (currently removed to simplify demo)
- Create GitHub Personal Access Token with repo/webhook permissions
- Deploy via Helm chart (configuration ready in codebase history)
- Configure webhook in GitHub repository settings

### Other Production Enhancements

**Infrastructure:**
- **Multi-environment setup** - Separate dev/staging/prod clusters with Terragrunt
- **External PostgreSQL** - Amazon RDS for Dagster metadata (vs in-cluster PostgreSQL)
- **Vault auto-unseal** - AWS KMS integration to eliminate manual unsealing
- **External DNS** - Automatic DNS management for LoadBalancer services
- **Cert-manager** - Automated TLS certificate provisioning with Let's Encrypt

**Security:**
- **Pod Security Standards** - Enforce restrictive pod security policies
- **Network Policies** - Restrict pod-to-pod communication
- **OPA/Kyverno** - Policy as Code for resource validation
- **Container scanning** - Trivy/Grype integration in CI pipeline
- **Secrets rotation** - Automated rotation of API keys and credentials

**Observability:**
- **Advanced alerting** - PagerDuty integration, SLO-based alerts

**Data Pipeline:**
- **Data quality checks** - Great Expectations integration
- **Data lineage** - OpenLineage tracking
- **ML model serving** - Seldon/KServe for model deployment
- **Real-time processing** - Apache Flink/Kafka for streaming data

---

## 📚 Documentation

| Document | Purpose |
|----------|---------|
| **[docs/SETUP.md](docs/SETUP.md)** | Complete deployment guide with prerequisites and step-by-step instructions |
| **[DEMO_GUIDE.md](DEMO_GUIDE.md)** | Interview/demo walkthrough script with timing and talking points |
| **[docs/WORKING_EXAMPLES.md](docs/WORKING_EXAMPLES.md)** | Live command examples and visual walkthrough proving the deployment works |
| **[docs/OPERATIONS.md](docs/OPERATIONS.md)** | Day-to-day operations, Vault management, and troubleshooting |
| **[docs/MONITORING.md](docs/MONITORING.md)** | Monitoring setup, dashboards, alerts, and metrics details |
| **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** | Architecture decisions, diagrams, and technical rationale |
| **[apps/README.md](apps/README.md)** | Application development guide and local testing |
