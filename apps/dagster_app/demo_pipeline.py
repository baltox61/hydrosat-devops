"""
Demo pipeline that fails 50% of the time to demonstrate monitoring and alerting.

This pipeline is designed for demonstration purposes in DevOps interviews to show:
- Alert firing when jobs fail
- Grafana dashboard metrics
- Alertmanager notifications
- Error handling and logging
"""
import os
import random
import time
from datetime import datetime, timezone
from typing import Dict, Any

from dagster import op, job, get_dagster_logger, Config, ScheduleDefinition, In, Out

class DemoConfig(Config):
    """Configuration for demo job"""
    failure_rate: float = 0.5  # 50% failure rate
    min_duration: int = 5  # Minimum execution time in seconds
    max_duration: int = 15  # Maximum execution time in seconds


@op(out=Out(Dict[str, Any]))
def generate_demo_data(context, config: DemoConfig) -> Dict[str, Any]:
    """
    Generate demo data and randomly succeed or fail.

    This op simulates a data generation step that:
    - Takes a random amount of time to execute
    - Has a configurable failure rate (default 50%)
    - Logs detailed execution information
    - Returns metadata about the execution
    """
    log = get_dagster_logger()

    # Simulate work with random duration
    duration = random.randint(config.min_duration, config.max_duration)
    log.info(f"Starting demo data generation (will take ~{duration}s)")

    start_time = time.time()

    # Simulate progressive work
    for i in range(duration):
        time.sleep(1)
        if i % 3 == 0:
            log.info(f"Progress: {int((i / duration) * 100)}%")

    elapsed = time.time() - start_time

    # Randomly decide if this run should fail
    should_fail = random.random() < config.failure_rate

    data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "execution_time": elapsed,
        "records_generated": random.randint(100, 1000),
        "should_fail": should_fail
    }

    log.info(f"Generated {data['records_generated']} demo records in {elapsed:.2f}s")

    if should_fail:
        log.error("❌ Simulating failure condition for demo purposes!")
        raise RuntimeError(
            f"Demo failure triggered (failure_rate={config.failure_rate}). "
            "This is intentional to demonstrate alerting. "
            f"Run details: {data}"
        )

    log.info("✅ Demo data generation completed successfully")
    return data


@op(ins={"data": In(Dict[str, Any])})
def process_demo_data(context, data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Process the demo data.

    This step only runs if the previous step succeeded.
    It simulates data processing and transformation.
    """
    log = get_dagster_logger()
    log.info(f"Processing {data['records_generated']} records...")

    time.sleep(3)  # Simulate processing time

    processed_data = {
        **data,
        "processed_at": datetime.now(timezone.utc).isoformat(),
        "status": "processed"
    }

    log.info("✅ Data processing completed successfully")
    return processed_data


@op(ins={"data": In(Dict[str, Any])})
def log_demo_results(context, data: Dict[str, Any]) -> str:
    """
    Log the final results.

    This is the final step that only runs if all previous steps succeeded.
    """
    log = get_dagster_logger()

    summary = f"""
    ╔══════════════════════════════════════════╗
    ║     DEMO JOB COMPLETED SUCCESSFULLY      ║
    ╚══════════════════════════════════════════╝

    📊 Run Summary:
    - Records Generated: {data['records_generated']}
    - Execution Time: {data['execution_time']:.2f}s
    - Generated At: {data['timestamp']}
    - Processed At: {data['processed_at']}
    - Status: {data['status']}

    ✨ This run succeeded! Monitor Grafana to see metrics.
    """

    log.info(summary)
    return "success"


@job(
    description="Demo job that fails 50% of the time to demonstrate monitoring and alerting"
)
def demo_flaky_job():
    """
    Demo job pipeline that intentionally fails half the time.

    Pipeline steps:
    1. generate_demo_data - Generates data, fails 50% of the time
    2. process_demo_data - Processes data (only if step 1 succeeds)
    3. log_demo_results - Logs results (only if step 2 succeeds)

    To test alerts:
    - Run this job multiple times
    - Watch Grafana dashboard for metrics
    - Check Alertmanager for firing alerts
    - Verify Slack notifications (if configured)
    """
    results = generate_demo_data()
    processed = process_demo_data(results)
    log_demo_results(processed)


# Schedule to run every 5 minutes for demo purposes
demo_schedule = ScheduleDefinition(
    job=demo_flaky_job,
    cron_schedule="*/5 * * * *",  # Every 5 minutes
    name="demo_flaky_schedule"
)


# Export for Dagster to discover
__all__ = ["demo_flaky_job", "demo_schedule"]
