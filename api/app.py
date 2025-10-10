import os, json
import boto3
from fastapi import FastAPI, HTTPException
from botocore.exceptions import ClientError

app = FastAPI()
s3 = boto3.client("s3")
BUCKET = os.getenv("WEATHER_RESULTS_BUCKET", "dagster-weather-products")
PREFIX = os.getenv("WEATHER_RESULTS_PREFIX", "weather-products/")

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
