import os, json, time
from pathlib import Path

import boto3
from fastapi import FastAPI, HTTPException, Request
from botocore.exceptions import ClientError
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

# Load environment from vault-agent generated .env file
def load_env_file(env_file_path: str = "/app/.env"):
    """Load environment variables from vault-agent generated .env file"""
    env_path = Path(env_file_path)
    if env_path.exists():
        with open(env_path, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    key, _, value = line.partition('=')
                    if key and value:
                        os.environ.setdefault(key.strip(), value.strip())

# Check for custom ENV_FILE location
env_file = os.getenv("ENV_FILE", "/app/.env")
load_env_file(env_file)

def read_secret(env_var_name: str, default: str = None) -> str:
    """
    Read secret from environment variable.
    Supports legacy *_FILE pattern for backward compatibility.
    """
    # Check for *_FILE pattern first (backward compatibility)
    file_path = os.getenv(f"{env_var_name}_FILE")
    if file_path and os.path.exists(file_path):
        with open(file_path, 'r') as f:
            return f.read().strip()

    # Read from environment (populated by vault-agent .env file)
    value = os.getenv(env_var_name, default)
    if not value:
        raise RuntimeError(f"{env_var_name} not set (checked env var and {env_var_name}_FILE)")
    return value

app = FastAPI()
s3 = boto3.client("s3")
BUCKET = read_secret("WEATHER_RESULTS_BUCKET", "dagster-weather-products")
PREFIX = os.getenv("WEATHER_RESULTS_PREFIX", "weather-products/")

# Prometheus metrics
http_requests_total = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status']
)

http_request_duration_seconds = Histogram(
    'http_request_duration_seconds',
    'HTTP request duration in seconds',
    ['method', 'endpoint'],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]
)

api_up = Gauge(
    'up',
    'API availability (1=up, 0=down)'
)

# Set API as up on startup
api_up.set(1)

@app.middleware("http")
async def prometheus_middleware(request: Request, call_next):
    """Middleware to track request metrics"""
    start_time = time.time()

    # Get endpoint path
    endpoint = request.url.path
    method = request.method

    try:
        response = await call_next(request)
        status_code = response.status_code

        # Record metrics
        http_requests_total.labels(
            method=method,
            endpoint=endpoint,
            status=str(status_code)
        ).inc()

        duration = time.time() - start_time
        http_request_duration_seconds.labels(
            method=method,
            endpoint=endpoint
        ).observe(duration)

        return response
    except Exception as e:
        # Record error
        http_requests_total.labels(
            method=method,
            endpoint=endpoint,
            status="500"
        ).inc()

        duration = time.time() - start_time
        http_request_duration_seconds.labels(
            method=method,
            endpoint=endpoint
        ).observe(duration)

        raise e

@app.get("/health")
def health():
    """Health check endpoint for Kubernetes probes"""
    return {"status": "healthy", "service": "products-api"}

@app.get("/metrics")
def metrics():
    """Prometheus metrics endpoint"""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/products")
def list_products(limit: int = 1):
    try:
        resp = s3.list_objects_v2(Bucket=BUCKET, Prefix=PREFIX)
        keys = sorted([o["Key"] for o in resp.get("Contents", []) if o["Key"].endswith(".jsonl")])
        if not keys: return []
        keys = keys[-limit:]
        items = []
        for k in keys:
            body = s3.get_object(Bucket=BUCKET, Key=k)["Body"].read().decode("utf-8")
            for line in body.splitlines():
                if line.strip():
                    items.append(json.loads(line))
        return items
    except ClientError as e:
        raise HTTPException(status_code=500, detail=str(e))
