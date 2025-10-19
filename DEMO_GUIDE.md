# Dagster DevOps Demo Guide

This guide walks you through demonstrating the complete Dagster weather pipeline deployment for DevOps interviews or presentations.

## 🎯 Demo Overview

This demo showcases a production-ready data pipeline deployment on AWS EKS with:
- **Dagster** - Data orchestration with scheduled jobs
- **HashiCorp Vault** - Secrets management with Kubernetes auth
- **Prometheus & Grafana** - Monitoring and alerting
- **AWS Services** - EKS, S3, ECR, IRSA for pod-level permissions
- **Infrastructure as Code** - OpenTofu/Terraform for everything

## 🚀 Quick Setup (5 minutes)

### 1. Set Up DNS Aliases

Run the DNS setup script to get nice URLs like `grafana.dagster.local`:

```bash
./scripts/setup_dns_aliases.sh
```

This will:
- Resolve LoadBalancer IPs for Grafana, Prometheus, and API
- Add entries to `/etc/hosts` for easy access
- Show you all access URLs and credentials

### 2. Access Your Services

After running the setup script, you can access:

**Grafana Dashboard:**
- URL: http://grafana.dagster.local
- Username: `admin`
- Password: `prom-operator`

**Prometheus:**
- URL: http://prometheus.dagster.local:9090

**Weather API:**
- URL: http://api.dagster.local:8080/products

**Dagster (Dagit):** (requires port-forward)
```bash
kubectl port-forward -n data svc/dagster-dagster-webserver 3001:80
```
- URL: http://dagster.dagster.local:3001

## 📋 Demo Script

### Part 1: Infrastructure Overview (5 min)

**Talk through the architecture:**

```bash
# Show the cluster
kubectl get nodes

# Show namespaces
kubectl get namespaces

# Show deployments
kubectl get deployments -n data
kubectl get deployments -n monitoring
```

**Key points to mention:**
- EKS cluster with Karpenter for autoscaling
- Separate namespaces for isolation (data, monitoring, vault, karpenter)
- LoadBalancers for external access
- Everything deployed via Infrastructure as Code

### Part 2: Weather Pipeline Demo (10 min)

**Show the production pipeline:**

1. **Open Dagster UI:**
   ```bash
   kubectl port-forward -n data svc/dagster-dagster-webserver 3001:80
   # Open: http://dagster.dagster.local:3001
   ```

2. **Navigate to Jobs:**
   - Click "Jobs" in the left sidebar
   - Show `weather_product_job`
   - Explain the 3-step pipeline:
     - `fetch_weather` - Calls OpenWeather API
     - `transform_weather` - Transforms to products
     - `upload_to_s3` - Stores in S3

3. **Show Schedules:**
   - Click "Schedules"
   - Show `weather_hourly` - runs every hour
   - Point out last run time

4. **Trigger Manual Run:**
   - Click "Launchpad" for `weather_product_job`
   - Click "Launch Run"
   - Watch it execute in real-time
   - Show logs for each step

5. **Verify S3 Data:**
   ```bash
   export AWS_PROFILE=balto
   aws s3 ls s3://dagster-weather-products/weather-products/ --recursive | tail -5

   # View the data
   aws s3 cp s3://dagster-weather-products/weather-products/2025/10/21/021534.jsonl - | jq
   ```

### Part 3: Secrets Management with Vault (5 min)

**Demonstrate secure secrets handling:**

1. **Show Vault is running:**
   ```bash
   kubectl get pods -n vault
   kubectl get svc -n vault
   ```

2. **Explain the flow:**
   - Vault Agent runs as init container
   - Authenticates using Kubernetes service account
   - Fetches secrets and writes to `/secrets/.env`
   - Application reads from `.env` file

3. **Show Vault configuration:**
   ```bash
   # Show vault agent config
   kubectl get configmap dagster-vault-config -n data -o yaml

   # Show the policy
   kubectl exec -n vault vault-0 -- vault policy read dagster-app
   ```

4. **Verify secrets are NOT in code:**
   ```bash
   # Show that API key is loaded from environment
   cat apps/dagster_app/weather_pipeline.py | grep -A5 "read_secret"
   ```

### Part 4: Monitoring & Alerting Demo (10 min)

**The star of the show - demonstrate monitoring:**

1. **Open Grafana:**
   - URL: http://grafana.dagster.local
   - Login with admin/prom-operator

2. **Show Built-in Dashboards:**
   - Navigate to Dashboards → Browse
   - Open "Kubernetes / Compute Resources / Namespace (Pods)"
   - Select `data` namespace
   - Show CPU/Memory usage graphs

3. **Import Custom Dashboard:**
   - Click "+" → Import
   - Upload `monitoring/dagster-dashboard.json`
   - Select Prometheus data source
   - Show the custom Dagster metrics

4. **View Active Alerts:**
   - Click Alerting → Alert rules
   - Show the 12 configured alerts
   - Explain severities (critical, warning, info)

5. **Demonstrate the Demo Flaky Job:**
   This is the **showstopper** - a job that fails 50% of the time to trigger alerts!

   ```bash
   # Port-forward to Dagster
   kubectl port-forward -n data svc/dagster-dagster-webserver 3001:80
   ```

   - Open http://dagster.dagster.local:3001
   - Navigate to `demo_flaky_job`
   - Explain: "This job randomly fails 50% of the time to demonstrate alerting"
   - Click "Launch Run" multiple times (3-5 runs)
   - **Some will succeed ✅, some will fail ❌**

6. **Show Alert Firing:**
   - Go back to Grafana → Alerting → Alert rules
   - Wait ~2 minutes for alert evaluation
   - Show **DemoJobFailed** alert firing
   - Point out the alert details, annotations

7. **Show in Prometheus:**
   - Open http://prometheus.dagster.local:9090
   - Navigate to Alerts tab
   - Show the firing alerts there too
   - Run a query: `dagster_job_failure_total{job_name="demo_flaky_job"}`
   - Show the metric increasing

8. **Explain Alert Routing** (if Slack configured):
   - Show `monitoring/alertmanager-config.yaml`
   - Explain routing rules:
     - Critical → Slack + PagerDuty
     - Warning → Slack
     - Demo alerts → Separate channel

### Part 5: CI/CD & Infrastructure (5 min)

**Show how everything is deployed:**

1. **Infrastructure as Code:**
   ```bash
   # Show Terraform/OpenTofu structure
   ls -la opentofu/

   # Key files to highlight:
   # - eks.tf - Cluster configuration
   # - dagster.tf - Dagster Helm chart
   # - vault.tf - Vault deployment
   # - monitoring.tf - Prometheus stack
   # - iam.tf - IRSA roles for S3 access
   ```

2. **Docker Image Build:**
   ```bash
   # Show the Dockerfile
   cat apps/dagster_app/Dockerfile

   # Show requirements
   cat apps/dagster_app/requirements.txt
   ```

3. **Deployment Scripts:**
   ```bash
   # Show deployment automation
   cat scripts/deploy_all.sh

   # Show testing script
   cat scripts/test_e2e.sh
   ```

## 🎬 Interview Q&A Preparation

### Expected Questions & Answers

**Q: How do you handle secrets in production?**
A: We use HashiCorp Vault with Kubernetes authentication. Vault Agent runs as an init container, authenticates using the pod's service account, fetches secrets based on policies, and writes them to a shared volume. The application reads from `/secrets/.env`. This ensures secrets are never in code, environment variables, or ConfigMaps.

**Q: How do you monitor job failures?**
A: Multi-layered approach:
1. Prometheus scrapes Dagster metrics (job success/failure counts)
2. PrometheusRules evaluate conditions (e.g., `dagster_job_failure_total` increase)
3. Alerts fire and route to Alertmanager
4. Alertmanager sends notifications (Slack, PagerDuty, Email)
5. Grafana dashboards visualize trends
We have 12 custom alerts covering job failures, high memory, pod restarts, etc.

**Q: How does the job access S3?**
A: Using IRSA (IAM Roles for Service Accounts). The Dagster service account has an annotation with an IAM role ARN. When pods run, they assume that role via OIDC federation. This is more secure than using static AWS credentials. The IAM role has fine-grained S3 permissions (read/write to specific bucket).

**Q: What happens if a job fails?**
A:
1. Dagster marks the run as failed in PostgreSQL
2. Prometheus detects `dagster_job_failure_total` metric increase
3. `DagsterJobFailed` alert fires after 1 minute
4. Alertmanager routes to Slack `#alerts-critical` channel
5. On-call engineer receives notification
6. Engineer checks Dagit UI for logs
7. Grafana dashboard shows failure trend
The demo_flaky_job demonstrates this end-to-end flow!

**Q: How do you scale this?**
A:
- EKS cluster uses Karpenter for node autoscaling
- Dagster uses K8sRunLauncher - each run is a separate Kubernetes Job
- Jobs scale horizontally automatically
- PostgreSQL for Dagster metadata (can use RDS for production)
- S3 for data storage scales infinitely
- Prometheus with long-term storage (Thanos/Cortex) for metrics

**Q: How do you ensure high availability?**
A:
- Multi-AZ EKS cluster
- Dagster webserver/daemon can run multiple replicas
- PostgreSQL with replication (RDS Multi-AZ in production)
- Vault in HA mode with Raft storage
- LoadBalancers distribute traffic
- PodDisruptionBudgets for controlled updates

**Q: How do you test this?**
A:
- Unit tests for pipeline code (pytest)
- Integration tests with `scripts/test_e2e.sh`
- Terraform validation before apply
- Staged deployments (dev → staging → prod)
- The demo_flaky_job itself is a test fixture for alerting

## 🔍 Troubleshooting During Demo

### If LoadBalancers aren't ready:
```bash
kubectl get svc -n monitoring kps-grafana
kubectl get svc -n monitoring kps-kube-prometheus-stack-prometheus

# If pending, wait or use port-forward instead
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```

### If demo job isn't showing:
```bash
# Check user deployment pod
kubectl get pods -n data -l "app=dagster-user-deployments"

# View logs
kubectl logs -n data deployment/dagster-dagster-user-deployments-weather

# Restart if needed
kubectl rollout restart deployment/dagster-dagster-user-deployments-weather -n data
```

### If alerts aren't firing:
```bash
# Check Prometheus targets are up
# Open: http://prometheus.dagster.local:9090/targets

# Check alert rules loaded
kubectl get prometheusrule -n monitoring | grep dagster

# View Prometheus logs
kubectl logs -n monitoring statefulset/prometheus-kps-kube-prometheus-stack-prometheus -c prometheus --tail=50
```

### If Vault secrets not loading:
```bash
# Check Vault is running
kubectl get pods -n vault

# Check init container logs
kubectl logs -n data <dagster-pod> -c vault-agent

# Verify service account has correct annotations
kubectl get sa dagster-dagster-user-deployments-user-deployments -n data -o yaml
```

## 📊 Demo Metrics to Highlight

Run these queries in Prometheus to show during demo:

```promql
# Job success rate (last 24h)
100 * (sum(increase(dagster_job_success_total[24h])) / sum(increase(dagster_job_total[24h])))

# Demo job failure rate
rate(dagster_job_failure_total{job_name="demo_flaky_job"}[1h]) / rate(dagster_job_total{job_name="demo_flaky_job"}[1h])

# Pod memory usage
sum(container_memory_working_set_bytes{namespace="data"}) by (pod) / 1024 / 1024

# Job duration
dagster_run_duration_seconds{job_name="weather_product_job"}
```

## 🎓 Key Demo Talking Points

1. **"This is production-ready"** - Not a toy example. Uses real AWS services, proper secrets management, monitoring.

2. **"Everything is code"** - Show the Git repository. All infrastructure, configuration, and application code.

3. **"Secure by default"** - Vault for secrets, IRSA for AWS access, RBAC for Kubernetes, no credentials in code.

4. **"Observable"** - Metrics, logs, traces. Multiple dashboards. Proactive alerts.

5. **"Scalable"** - Horizontal scaling, autoscaling, designed for growth.

6. **"The demo job shows it works"** - Point out that failures are intentional and alerts fire correctly.

## 📝 Cleanup After Demo

```bash
# Remove DNS aliases
./scripts/setup_dns_aliases.sh remove

# (Optional) Tear down infrastructure
./scripts/teardown_all.sh
```

## 🎯 Success Metrics

Your demo was successful if you showed:
- ✅ A working data pipeline fetching real data
- ✅ Secrets loaded from Vault (not hardcoded)
- ✅ Data written to S3 with IRSA
- ✅ Monitoring dashboards with real metrics
- ✅ Alerts firing when jobs fail
- ✅ All deployed via Infrastructure as Code
- ✅ Professional presentation with nice URLs

## 💡 Pro Tips

1. **Practice the demo 2-3 times** - Know where things are, anticipate questions
2. **Have backup plan** - If LoadBalancer isn't ready, use port-forward
3. **Run demo job 5 times before interview** - Ensures some data in Grafana
4. **Open all tabs beforehand** - Grafana, Prometheus, Dagster, AWS Console
5. **Explain as you click** - "I'm navigating to the Jobs page to show our pipelines..."
6. **Highlight the failures** - "See this red run? That's intentional - triggers our alert"

Good luck! 🚀
