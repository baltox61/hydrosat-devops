# dagster_weather package
# This makes the dagster_weather directory a Python package

# Initialize Prometheus metrics server on package import
from dagster_weather.dagster_metrics import init_metrics_server
init_metrics_server(port=9090)

from dagster import Definitions
from dagster_weather.weather_pipeline import weather_product_job, weather_hourly
from dagster_weather.demo_pipeline import demo_flaky_job, demo_schedule

# Combined definitions for all jobs and schedules
defs = Definitions(
    jobs=[weather_product_job, demo_flaky_job],
    schedules=[weather_hourly, demo_schedule],
)
