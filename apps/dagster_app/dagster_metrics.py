"""
Prometheus metrics instrumentation for Dagster pipelines.

This module provides metrics tracking for job runs, steps, and daemon health.
Metrics are exposed on port 9090 via HTTP server for Prometheus scraping.
Optionally pushes metrics to Pushgateway for persistence after job completion.
"""

import os
import threading
import time
from prometheus_client import Counter, Gauge, Histogram, start_http_server, REGISTRY, push_to_gateway
from dagster import get_dagster_logger, success_hook, failure_hook, HookContext

# Configuration - can be disabled by setting PUSHGATEWAY_URL to empty string
# Pushgateway is disabled by default since we use PodMonitor for direct scraping
PUSHGATEWAY_URL = os.getenv('PUSHGATEWAY_URL', '')
PUSHGATEWAY_ENABLED = bool(PUSHGATEWAY_URL)

# Job-level metrics
dagster_job_total = Counter(
    'dagster_job_total',
    'Total number of Dagster jobs started',
    ['job_name']
)

dagster_job_success_total = Counter(
    'dagster_job_success_total',
    'Total number of successful Dagster jobs',
    ['job_name']
)

dagster_job_failure_total = Counter(
    'dagster_job_failure_total',
    'Total number of failed Dagster jobs',
    ['job_name']
)

dagster_run_duration_seconds = Histogram(
    'dagster_run_duration_seconds',
    'Duration of Dagster job runs in seconds',
    ['job_name'],
    buckets=[1, 5, 10, 30, 60, 120, 180, 300, 600, 1800, 3600]
)

# Step-level metrics
dagster_step_total = Counter(
    'dagster_step_total',
    'Total number of Dagster steps started',
    ['job_name', 'step_name']
)

dagster_step_success_total = Counter(
    'dagster_step_success_total',
    'Total number of successful Dagster steps',
    ['job_name', 'step_name']
)

dagster_step_failure_total = Counter(
    'dagster_step_failure_total',
    'Total number of failed Dagster steps',
    ['job_name', 'step_name']
)

# Runtime metrics
dagster_jobs_running = Gauge(
    'dagster_jobs_running',
    'Number of currently running Dagster jobs'
)

# Daemon health (simple heartbeat)
dagster_daemon_heartbeat = Gauge(
    'dagster_daemon_heartbeat',
    'Dagster daemon heartbeat (1=alive, 0=dead)'
)

# Set daemon heartbeat to 1 on module load
dagster_daemon_heartbeat.set(1)


class MetricsServer:
    """HTTP server for exposing Prometheus metrics."""

    def __init__(self, port=9090):
        self.port = port
        self.server_thread = None
        self._started = False

    def start(self):
        """Start the metrics HTTP server in a background thread."""
        if self._started:
            return

        try:
            # Start HTTP server in daemon thread
            self.server_thread = threading.Thread(
                target=self._run_server,
                daemon=True,
                name="PrometheusMetricsServer"
            )
            self.server_thread.start()
            self._started = True

            log = get_dagster_logger()
            log.info(f"Prometheus metrics server started on port {self.port}")
        except Exception as e:
            log = get_dagster_logger()
            log.error(f"Failed to start Prometheus metrics server: {e}")

    def _run_server(self):
        """Run the Prometheus HTTP server."""
        try:
            start_http_server(self.port)
            # Keep thread alive
            while True:
                time.sleep(60)
                # Update daemon heartbeat
                dagster_daemon_heartbeat.set(1)
        except Exception as e:
            log = get_dagster_logger()
            log.error(f"Prometheus metrics server error: {e}")


# Global metrics server instance
_metrics_server = None


def init_metrics_server(port=9090):
    """Initialize and start the Prometheus metrics server."""
    global _metrics_server
    if _metrics_server is None:
        _metrics_server = MetricsServer(port=port)
        _metrics_server.start()
    return _metrics_server


class JobMetricsContext:
    """Context manager for tracking job execution metrics."""

    def __init__(self, job_name: str):
        self.job_name = job_name
        self.start_time = None

    def __enter__(self):
        """Start tracking job execution."""
        self.start_time = time.time()
        dagster_job_total.labels(job_name=self.job_name).inc()
        dagster_jobs_running.inc()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Record job completion metrics."""
        duration = time.time() - self.start_time
        dagster_run_duration_seconds.labels(job_name=self.job_name).observe(duration)
        dagster_jobs_running.dec()

        if exc_type is None:
            # Success
            dagster_job_success_total.labels(job_name=self.job_name).inc()
        else:
            # Failure
            dagster_job_failure_total.labels(job_name=self.job_name).inc()

        return False  # Don't suppress exceptions


class StepMetricsContext:
    """Context manager for tracking step execution metrics."""

    def __init__(self, job_name: str, step_name: str):
        self.job_name = job_name
        self.step_name = step_name

    def __enter__(self):
        """Start tracking step execution."""
        dagster_step_total.labels(
            job_name=self.job_name,
            step_name=self.step_name
        ).inc()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Record step completion metrics."""
        if exc_type is None:
            # Success
            dagster_step_success_total.labels(
                job_name=self.job_name,
                step_name=self.step_name
            ).inc()
        else:
            # Failure
            dagster_step_failure_total.labels(
                job_name=self.job_name,
                step_name=self.step_name
            ).inc()

        return False  # Don't suppress exceptions


def push_metrics_to_gateway(job_name: str):
    """Push current metrics to Pushgateway for persistence."""
    if not PUSHGATEWAY_ENABLED:
        return

    try:
        # Push metrics with job-specific grouping key
        push_to_gateway(
            gateway=PUSHGATEWAY_URL,
            job=f'dagster-{job_name}',
            registry=REGISTRY
        )
        log = get_dagster_logger()
        log.info(f"Pushed metrics to Pushgateway for job {job_name}")
    except Exception as e:
        log = get_dagster_logger()
        log.warning(f"Failed to push metrics to Pushgateway: {e}")


# Dagster hooks for job-level metrics
_job_start_times = {}


@success_hook
def job_success_hook(context: HookContext):
    """Hook to track successful job completions."""
    job_name = context.job_name
    run_id = context.run_id

    # Track success
    dagster_job_success_total.labels(job_name=job_name).inc()
    dagster_job_total.labels(job_name=job_name).inc()

    # Track duration if start time was recorded
    if run_id in _job_start_times:
        duration = time.time() - _job_start_times[run_id]
        dagster_run_duration_seconds.labels(job_name=job_name).observe(duration)
        del _job_start_times[run_id]

    log = get_dagster_logger()
    log.info(f"Metrics: Job {job_name} completed successfully (run_id={run_id})")

    # Push metrics to Pushgateway for persistence
    push_metrics_to_gateway(job_name)


@failure_hook
def job_failure_hook(context: HookContext):
    """Hook to track failed job completions."""
    job_name = context.job_name
    run_id = context.run_id

    # Track failure
    dagster_job_failure_total.labels(job_name=job_name).inc()
    dagster_job_total.labels(job_name=job_name).inc()

    # Track duration if start time was recorded
    if run_id in _job_start_times:
        duration = time.time() - _job_start_times[run_id]
        dagster_run_duration_seconds.labels(job_name=job_name).observe(duration)
        del _job_start_times[run_id]

    log = get_dagster_logger()
    log.error(f"Metrics: Job {job_name} failed (run_id={run_id})")

    # Push metrics to Pushgateway for persistence
    push_metrics_to_gateway(job_name)
