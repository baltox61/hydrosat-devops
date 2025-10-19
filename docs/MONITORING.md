# Monitoring & Alerting Guide

Complete guide for monitoring your Dagster weather pipeline with Grafana, Prometheus, and Alertmanager.

---

## 🚀 Quick Access

### Service URLs

After running the DNS setup script, access services at:

```bash
# Set up friendly URLs (requires sudo password)
./scripts/setup_dns_aliases.sh

# Then access:
# Grafana:     http://grafana.dagster.local
# Prometheus:  http://prometheus.dagster.local:9090
# API:         http://api.dagster.local:8080
```

**Grafana Credentials:**
- Username: `admin`
- Password: `prom-operator`

### Port-Forward Alternative

```bash
# Grafana
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# Then: http://localhost:3000

# Prometheus
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090
# Then: http://localhost:9090

# Alertmanager
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-alertmanager 9093:9093
# Then: http://localhost:9093
```

---

## 📊 What's Deployed

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **Grafana** | Dashboards & visualization | monitoring |
| **Prometheus** | Metrics collection & storage | monitoring |
| **Alertmanager** | Alert routing & notifications | monitoring |
| **Node Exporter** | Node/hardware metrics | monitoring |
| **Kube State Metrics** | Kubernetes resource metrics | monitoring |

---

## 🔔 Active Alerts

### Critical Alerts 🚨

| Alert | Trigger | Action |
|-------|---------|--------|
| **DagsterJobFailed** | Any job failure in 5min | Check Dagit UI → Runs → Logs |
| **S3UploadFailures** | S3 upload step fails | Verify IRSA permissions, S3 bucket access |
| **VaultAuthenticationFailure** | Pod start errors | Check Vault service, SA bindings |

### Warning Alerts ⚠️

| Alert | Trigger | Action |
|-------|---------|--------|
| **DagsterDaemonDown** | Daemon down >5min | Restart daemon deployment |
| **WeatherPipelineStale** | No success in 2h | Check scheduler, cron config |
| **DagsterHighFailureRate** | >50% jobs failing | Investigate systemic issues |
| **DagsterWebserverDown** | UI down >5min | Check webserver pods |
| **DagsterHighMemoryUsage** | Pod using >90% memory | Review resource limits |
| **DagsterPodRestarting** | Pod restarts detected | Check logs for OOMKilled |

### Demo Alerts (for interviews) 📺

| Alert | Trigger | Purpose |
|-------|---------|---------|
| **DemoJobFailed** | demo_flaky_job fails | Shows alerting works |
| **DemoJobHighFailureRate** | >60% failure rate | Demonstrates metric evaluation |

### Info Alerts ℹ️

| Alert | Trigger | Action |
|-------|---------|--------|
| **DagsterJobSlow** | Job takes >3min | Monitor performance trends |

---

## 🎯 Key Metrics

Query these in Prometheus or use in Grafana dashboards:

```promql
# Job success rate (last 24h)
100 * (sum(increase(dagster_job_success_total[24h])) / sum(increase(dagster_job_total[24h])))

# Failed jobs (last hour)
sum(increase(dagster_job_failure_total[1h]))

# Average job duration
avg(dagster_run_duration_seconds{job_name="weather_product_job"})

# Memory usage by pod (MB)
sum(container_memory_working_set_bytes{namespace="data"}) by (pod) / 1024 / 1024

# CPU usage by pod
sum(rate(container_cpu_usage_seconds_total{namespace="data"}[5m])) by (pod)

# Pod count by status
count(kube_pod_status_phase{namespace="data"}) by (phase)

# Demo job failure rate
rate(dagster_job_failure_total{job_name="demo_flaky_job"}[1h]) /
rate(dagster_job_total{job_name="demo_flaky_job"}[1h])
```

---

## 📈 Grafana Dashboards

### Import Custom Dagster Dashboard

1. Login to Grafana (http://grafana.dagster.local)
2. Click "+" (Create) → "Import"
3. Click "Upload JSON file"
4. Select `monitoring/dagster-dashboard.json`
5. Select "Prometheus" as data source
6. Click "Import"

### Dashboard Panels

The custom dashboard includes:
- **Job Success Rate** - % successful in last 24h
- **Total Jobs Run** - Execution count
- **Failed Jobs** - Failure count (should be 0!)
- **Avg Job Duration** - Performance trend
- **Job Runs Over Time** - Success/failure timeline
- **Job Duration Trend** - Execution time graph
- **Step Success Rate** - Per-step metrics
- **Pod Memory Usage** - Memory by pod
- **Pod CPU Usage** - CPU utilization
- **Active Pods** - Running pod list

### Pre-built Kubernetes Dashboards

Navigate to Dashboards → Browse to find:
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace (Pods)
- Kubernetes / Compute Resources / Pod
- Node Exporter / Nodes
- Prometheus / Overview

---

## 🔧 Alert Configuration

### Files

- **`monitoring/alertmanager-config.yaml`** - Notification channels (Slack, Email, PagerDuty)
- **`monitoring/dagster-alerts.yaml`** - Custom Prometheus alert rules (already applied)

### Setup Slack Notifications

1. **Get Slack Webhook URL:**
   - Go to https://api.slack.com/messaging/webhooks
   - Create a new webhook for your workspace
   - Copy the webhook URL

2. **Edit Alertmanager Config:**
   ```bash
   vi monitoring/alertmanager-config.yaml
   ```

   Update the `slack_api_url`:
   ```yaml
   global:
     slack_api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
   ```

   Configure channels:
   ```yaml
   receivers:
     - name: 'slack-critical'
       slack_configs:
         - channel: '#alerts-critical'
           # ... rest of config

     - name: 'slack-dagster'
       slack_configs:
         - channel: '#dagster-alerts'
           # ... rest of config
   ```

3. **Apply Configuration:**
   ```bash
   # Create secret from config file
   kubectl create secret generic alertmanager-kps-kube-prometheus-stack-alertmanager \
     --from-file=alertmanager.yaml=monitoring/alertmanager-config.yaml \
     --namespace=monitoring \
     --dry-run=client -o yaml | kubectl apply -f -

   # Restart Alertmanager to pick up changes
   kubectl rollout restart statefulset alertmanager-kps-kube-prometheus-stack-alertmanager -n monitoring
   ```

### Setup Email Notifications

For Gmail with App Password:

1. Enable 2FA on your Google account
2. Generate App Password: https://myaccount.google.com/apppasswords
3. Update `monitoring/alertmanager-config.yaml`:

```yaml
receivers:
  - name: 'email-ops'
    email_configs:
      - to: 'ops-team@example.com'
        from: 'alertmanager@example.com'
        smarthost: 'smtp.gmail.com:587'
        auth_username: 'alertmanager@example.com'
        auth_password: 'YOUR_APP_PASSWORD'
```

### Setup PagerDuty

1. Go to your PagerDuty service
2. Navigate to Integrations → Add Integration
3. Select "Prometheus" integration type
4. Copy the Integration Key
5. Update config:

```yaml
receivers:
  - name: 'pagerduty-critical'
    pagerduty_configs:
      - service_key: 'YOUR_PAGERDUTY_INTEGRATION_KEY'
```

---

## 🧪 Testing Alerts

### Manual Test Alert

```bash
# Port-forward to Alertmanager
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-alertmanager 9093:9093

# Send test alert via API
curl -XPOST http://localhost:9093/api/v1/alerts -d '[{
  "labels": {"alertname": "TestAlert", "severity": "warning"},
  "annotations": {"summary": "Test notification from Alertmanager"}
}]'

# Check Slack/Email for notification
```

### Trigger Real Alert with Demo Job

The **demo_flaky_job** is perfect for testing:

```bash
# Port-forward to Dagster
kubectl port-forward -n data svc/dagster-dagster-webserver 3001:80

# Open http://dagster.dagster.local:3001
# Navigate to demo_flaky_job
# Click "Launch Run" 5-10 times
# Some runs will fail (50% failure rate)
# Wait 2-3 minutes for alert to fire
# Check Grafana → Alerting → Alert rules
# See DemoJobFailed alert firing
```

### Verify Alert Rules

```bash
# Check PrometheusRules are loaded
kubectl get prometheusrule -n monitoring | grep dagster

# View alert configuration
kubectl get prometheusrule dagster-weather-pipeline-alerts -n monitoring -o yaml

# Check Prometheus UI
# Open: http://prometheus.dagster.local:9090/alerts
# Should see all configured alerts
```

---

## 🔍 Troubleshooting

### No Data in Grafana

**Check Prometheus Targets:**
```bash
# Open: http://prometheus.dagster.local:9090/targets
# Ensure all targets show "UP"
```

**Verify Data Source:**
1. Grafana → Settings → Data Sources
2. Click "Prometheus"
3. Click "Test" - should show "Data source is working"

**Test Query Directly:**
```bash
# In Prometheus UI (port 9090) → Graph
# Query: up
# Should return results
```

### Alerts Not Firing

**Check Rules Loaded:**
```bash
kubectl get prometheusrule -n monitoring

# Should show:
# - kps-kube-prometheus-stack-* (many)
# - dagster-weather-pipeline-alerts
```

**View Prometheus Logs:**
```bash
kubectl logs -n monitoring statefulset/prometheus-kps-kube-prometheus-stack-prometheus \
  -c prometheus --tail=100
```

**Check Alert Evaluation:**
```bash
# Open Prometheus UI → Alerts
# Check "State" column:
# - Inactive = not triggered
# - Pending = condition met, waiting for "for" duration
# - Firing = alert active
```

### Notifications Not Sending

**Check Alertmanager Config:**
```bash
kubectl get secret alertmanager-kps-kube-prometheus-stack-alertmanager \
  -n monitoring -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

**View Alertmanager Logs:**
```bash
kubectl logs -n monitoring statefulset/alertmanager-kps-kube-prometheus-stack-alertmanager \
  -c alertmanager --tail=100
```

**Check Alertmanager UI:**
```bash
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-alertmanager 9093:9093
# Open: http://localhost:9093
# Go to Status page
# Check routing tree configuration
```

**Test Webhook Manually:**
```bash
# For Slack webhook
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"Test from Alertmanager"}' \
  https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK
```

### Dashboard Not Showing Data

**Verify Metrics Exist:**
```bash
# Query in Prometheus
# http://prometheus.dagster.local:9090/graph
# Try: dagster_job_total
# Should return values
```

**Check Time Range:**
- Grafana dashboards default to "Last 6 hours"
- If no recent job runs, adjust time range
- Top right corner → time picker

**Refresh Dashboard:**
- Click the refresh button (circular arrow icon)
- Or set auto-refresh interval

---

## 📋 Common Operations

### View Current Alerts

```bash
# In Prometheus UI
# http://prometheus.dagster.local:9090/alerts

# Or via CLI
kubectl exec -n monitoring prometheus-kps-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/alerts 2>/dev/null | jq '.data.alerts[] | {alert: .labels.alertname, state: .state}'
```

### Silence an Alert

1. Open Alertmanager UI: http://localhost:9093 (with port-forward)
2. Click "Silences" → "New Silence"
3. Add matcher: `alertname="DemoJobFailed"`
4. Set duration (e.g., 2 hours)
5. Add comment: "Testing - ignoring demo failures"
6. Click "Create"

### Add New Alert Rule

1. Edit `monitoring/dagster-alerts.yaml`
2. Add new rule under `spec.groups[0].rules`:

```yaml
- alert: MyNewAlert
  expr: my_metric > threshold
  for: 5m
  labels:
    severity: warning
    component: dagster
  annotations:
    summary: "Brief description"
    description: "Detailed info with {{ $labels.pod }}"
```

3. Apply changes:
```bash
kubectl apply -f monitoring/dagster-alerts.yaml
```

### Update Alertmanager Config

```bash
# Edit config
vi monitoring/alertmanager-config.yaml

# Apply
kubectl create secret generic alertmanager-kps-kube-prometheus-stack-alertmanager \
  --from-file=alertmanager.yaml=monitoring/alertmanager-config.yaml \
  --namespace=monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart
kubectl rollout restart statefulset alertmanager-kps-kube-prometheus-stack-alertmanager -n monitoring
```

### Check What's Being Monitored

```bash
# List ServiceMonitors (what Prometheus scrapes)
kubectl get servicemonitor -n monitoring

# List PodMonitors
kubectl get podmonitor -n monitoring

# View Prometheus config
kubectl get configmap prometheus-kps-kube-prometheus-stack-prometheus -n monitoring -o yaml
```

---

## 📚 Additional Resources

- **Prometheus Query Language:** https://prometheus.io/docs/prometheus/latest/querying/basics/
- **Grafana Documentation:** https://grafana.com/docs/grafana/latest/
- **Alertmanager Config:** https://prometheus.io/docs/alerting/latest/configuration/
- **Dagster Metrics:** https://docs.dagster.io/deployment/guides/kubernetes/monitoring

---

## 🎯 Quick Command Reference

```bash
# Access Grafana
kubectl port-forward -n monitoring svc/kps-grafana 3000:80

# Access Prometheus
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090

# Access Alertmanager
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-alertmanager 9093:9093

# View Grafana password
kubectl get secret kps-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# List all alerts
kubectl get prometheusrule -n monitoring

# View specific alert
kubectl get prometheusrule dagster-weather-pipeline-alerts -n monitoring -o yaml

# Check Prometheus targets
# Open: http://localhost:9090/targets (with port-forward)

# View pod metrics
kubectl top pods -n data

# Test alert notification
curl -XPOST http://localhost:9093/api/v1/alerts -d '[{"labels":{"alertname":"Test"},"annotations":{"summary":"Test"}}]'
```
