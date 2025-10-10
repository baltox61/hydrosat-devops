import os, json, time, hashlib
from datetime import datetime, timezone
from typing import List, Dict, Any

import boto3, requests
from dagster import op, job, get_dagster_logger, Config, ScheduleDefinition

OPENWEATHER_URL = "https://api.openweathermap.org/data/2.5/weather"

class FetchConfig(Config):
    coords: List[Dict[str, float]] = [
        {"name": "Luxembourg", "lat": 49.6116, "lon": 6.1319},
        {"name": "Chicago", "lat": 41.8781, "lon": -87.6298},
    ]
    units: str = "metric"

class S3Config(Config):
    bucket: str = os.getenv("WEATHER_RESULTS_BUCKET", "dagster-weather-products")
    prefix: str = "weather-products/"

@op
def fetch_weather(_, config: FetchConfig) -> List[Dict[str, Any]]:
    log = get_dagster_logger()
    api_key = os.getenv("OPENWEATHER_API_KEY")
    if not api_key:
        raise RuntimeError("OPENWEATHER_API_KEY not set")

    out = []
    for c in config.coords:
        r = requests.get(OPENWEATHER_URL, params={"lat": c["lat"], "lon": c["lon"], "appid": api_key, "units": config.units}, timeout=20)
        r.raise_for_status()
        data = r.json()
        data["_meta"] = {"requested_name": c.get("name"), "requested_lat": c["lat"], "requested_lon": c["lon"]}
        out.append(data)
        time.sleep(0.2)
        log.info(f"Fetched weather for {c.get('name', f'{c['lat']},{c['lon']}')}")
    return out

@op
def transform_weather(_, raw: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    ts = datetime.now(timezone.utc).isoformat()
    products = []
    for w in raw:
        main = w.get("main", {}); wind = w.get("wind", {}); sys = w.get("sys", {})
        name = (w.get("_meta") or {}).get("requested_name") or w.get("name")
        lat = (w.get("coord") or {}).get("lat"); lon = (w.get("coord") or {}).get("lon")
        products.append({
            "id": hashlib.sha1(f"{lat},{lon},{w.get('dt')}".encode()).hexdigest()[:16],
            "collected_at": ts, "location_name": name, "lat": lat, "lon": lon,
            "temp": main.get("temp"), "feels_like": main.get("feels_like"),
            "humidity": main.get("humidity"), "pressure": main.get("pressure"),
            "wind_speed": wind.get("speed"), "wind_deg": wind.get("deg"),
            "weather": (w.get("weather") or [{}])[0].get("description"),
            "sunrise": sys.get("sunrise"), "sunset": sys.get("sunset"),
            "source": "openweathermap_current",
        })
    return products

@op
def upload_to_s3(_, config: S3Config, products: List[Dict[str, Any]]) -> str:
    if not products: return ""
    s3 = boto3.client("s3")
    now = datetime.utcnow()
    key = f"{config.prefix}{now:%Y/%m/%d}/{now:%H%M%S}.jsonl"
    body = "\n".join(json.dumps(p, separators=(",", ":"), sort_keys=True) for p in products)
    s3.put_object(Bucket=config.bucket, Key=key, Body=body.encode("utf-8"), ContentType="application/json")
    return f"s3://{config.bucket}/{key}"

@job
def weather_product_job():
    upload_to_s3(transform_weather(fetch_weather()))

weather_hourly = ScheduleDefinition(job=weather_product_job, cron_schedule="0 * * * *")
