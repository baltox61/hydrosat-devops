#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo ""
log_info "=========================================="
log_info "  Local Application Testing"
log_info "=========================================="
echo ""

# Change to apps directory
cd "$(dirname "$0")/../apps"
log_info "Working directory: $(pwd)"
echo ""

# Check prerequisites
log_info "Checking prerequisites..."

command -v python3 >/dev/null 2>&1 || { log_error "python3 not found. Please install Python 3.11+"; exit 1; }
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
log_success "Python $PYTHON_VERSION found"

command -v pip3 >/dev/null 2>&1 || { log_error "pip3 not found. Please install pip"; exit 1; }
log_success "pip3 found"

echo ""

# Create virtual environment
log_info "Setting up virtual environment..."
if [ ! -d "venv" ]; then
    python3 -m venv venv
    log_success "Virtual environment created"
else
    log_info "Virtual environment already exists"
fi

# Activate virtual environment
source venv/bin/activate
log_success "Virtual environment activated"

echo ""
log_info "Installing dependencies from requirements.txt..."
pip install -q --upgrade pip
pip install -q -r requirements.txt

# Also install development dependencies
pip install -q dagster-webserver pytest httpx

log_success "Dependencies installed"
echo ""

# Test 1: Python syntax check
log_info "Test 1: Checking Python syntax..."
python3 -m py_compile api.py
python3 -m py_compile dagster_app/weather_pipeline.py
python3 -m py_compile dagster_app/__init__.py
log_success "All Python files have valid syntax"
echo ""

# Test 2: Import check for API
log_info "Test 2: Testing API imports..."
python3 -c "import api; print('API module loaded successfully')"
log_success "API module imports successfully"
echo ""

# Test 3: Import check for Dagster
log_info "Test 3: Testing Dagster imports..."
python3 -c "
import sys
sys.path.insert(0, '.')
from dagster_app.weather_pipeline import weather_product_job, fetch_weather, transform_weather, upload_to_s3
print('Dagster pipeline loaded successfully')
print(f'Job name: {weather_product_job.name}')
"
log_success "Dagster pipeline imports successfully"
echo ""

# Test 4: FastAPI app creation
log_info "Test 4: Testing FastAPI app creation..."
python3 << 'PYTHON_SCRIPT'
import os
os.environ["WEATHER_RESULTS_BUCKET"] = "test-bucket"
os.environ["WEATHER_RESULTS_PREFIX"] = "test-prefix/"

import api
app = api.app

# Check routes exist
routes = [route.path for route in app.routes]
assert "/health" in routes, "Missing /health endpoint"
assert "/products" in routes, "Missing /products endpoint"

print(f"API has {len(routes)} routes: {routes}")
print("FastAPI app created successfully")
PYTHON_SCRIPT
log_success "FastAPI app structure is valid"
echo ""

# Test 5: Health endpoint mock test
log_info "Test 5: Testing health endpoint logic..."
python3 << 'PYTHON_SCRIPT'
import os
os.environ["WEATHER_RESULTS_BUCKET"] = "test-bucket"
os.environ["WEATHER_RESULTS_PREFIX"] = "test-prefix/"

from fastapi.testclient import TestClient
import api

client = TestClient(api.app)
response = client.get("/health")
assert response.status_code == 200, f"Expected 200, got {response.status_code}"
data = response.json()
assert data["status"] == "healthy", "Health check failed"
assert data["service"] == "products-api", "Service name mismatch"
print(f"Health endpoint response: {data}")
PYTHON_SCRIPT
log_success "Health endpoint works correctly"
echo ""

# Test 6: Dagster job structure
log_info "Test 6: Testing Dagster job structure..."
python3 << 'PYTHON_SCRIPT'
import sys
sys.path.insert(0, '.')
from dagster_app.weather_pipeline import weather_product_job

# Check job has ops
job = weather_product_job
print(f"Job: {job.name}")
print(f"Ops in job: {[node.name for node in job.graph.nodes]}")

# Verify expected ops
expected_ops = ["fetch_weather", "transform_weather", "upload_to_s3"]
actual_ops = [node.name for node in job.graph.nodes]

for expected in expected_ops:
    if expected in actual_ops:
        print(f"  ✓ {expected} found")
    else:
        print(f"  ✗ {expected} MISSING")
        sys.exit(1)

print("All expected ops present")
PYTHON_SCRIPT
log_success "Dagster job structure is correct"
echo ""

# Test 7: Secret reading helper function
log_info "Test 7: Testing secret reading functions..."
python3 << 'PYTHON_SCRIPT'
import os
import sys
sys.path.insert(0, '.')

# Test API secret reader
from api import read_secret

# Test env var fallback
os.environ["TEST_SECRET"] = "from_env"
result = read_secret("TEST_SECRET")
assert result == "from_env", f"Expected 'from_env', got '{result}'"
print("✓ API read_secret works with env vars")

# Test file reading
import tempfile
with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
    f.write("from_file")
    temp_path = f.name

os.environ["TEST_SECRET_FILE"] = temp_path
result = read_secret("TEST_SECRET")
assert result == "from_file", f"Expected 'from_file', got '{result}'"
print("✓ API read_secret works with files")

os.unlink(temp_path)

# Test Dagster secret reader
from dagster_app.weather_pipeline import read_secret as dagster_read_secret

os.environ["TEST_SECRET2"] = "dagster_env"
result = dagster_read_secret("TEST_SECRET2")
assert result == "dagster_env", f"Expected 'dagster_env', got '{result}'"
print("✓ Dagster read_secret works with env vars")

print("Secret reading functions work correctly")
PYTHON_SCRIPT
log_success "Secret reading helpers work correctly"
echo ""

# Test 8: Dagster CLI availability
log_info "Test 8: Testing Dagster CLI..."
dagster --version
log_success "Dagster CLI is available"
echo ""

# Summary
echo ""
log_info "=========================================="
log_success "  All Tests Passed! ✓"
log_info "=========================================="
echo ""

log_info "Next steps for local development:"
echo ""
echo "  ${GREEN}1. Test API locally:${NC}"
echo "     export WEATHER_RESULTS_BUCKET=\"dagster-weather-products\""
echo "     export WEATHER_RESULTS_PREFIX=\"weather-products/\""
echo "     export AWS_PROFILE=\"your-profile\"  # or use AWS_ACCESS_KEY_ID/SECRET"
echo "     uvicorn api:app --reload --port 8000"
echo "     # Visit: http://localhost:8000/health"
echo ""
echo "  ${GREEN}2. Test Dagster locally:${NC}"
echo "     export OPENWEATHER_API_KEY=\"your-api-key\""
echo "     export WEATHER_RESULTS_BUCKET=\"dagster-weather-products\""
echo "     export AWS_PROFILE=\"your-profile\"  # or use AWS_ACCESS_KEY_ID/SECRET"
echo "     dagster dev -f dagster_app/weather_pipeline.py"
echo "     # Visit: http://localhost:3000"
echo ""
echo "  ${GREEN}3. Run manual Dagster job:${NC}"
echo "     dagster job execute -f dagster_app/weather_pipeline.py -j weather_product_job"
echo ""

log_info "To deactivate virtual environment: deactivate"
echo ""
