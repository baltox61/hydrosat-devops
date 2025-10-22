# Dagster User Code Deployment
# Multi-stage build for smaller final image

FROM python:3.11-slim as builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# Final stage
FROM python:3.11-slim

WORKDIR /opt/dagster/app

# Install runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user first
RUN useradd -m -u 1000 dagster

# Copy Python packages from builder to user location
COPY --from=builder /root/.local /home/dagster/.local

# Change ownership of packages
RUN chown -R dagster:dagster /home/dagster/.local

# Create directory structure for dagster_weather module
RUN mkdir -p dagster_weather

# Copy application code into module directory
COPY __init__.py dagster_weather/__init__.py
COPY dagster_metrics.py dagster_weather/dagster_metrics.py
COPY weather_pipeline.py dagster_weather/weather_pipeline.py
COPY demo_pipeline.py dagster_weather/demo_pipeline.py

# Create directory for Dagster home
RUN mkdir -p /opt/dagster/dagster_home
ENV DAGSTER_HOME=/opt/dagster/dagster_home

# Create directory for secrets (mounted by Vault Agent)
RUN mkdir -p /secrets

# Change ownership of application directories
RUN chown -R dagster:dagster /opt/dagster

# Switch to non-root user
USER dagster

# Set working directory explicitly for the user
WORKDIR /opt/dagster/app

# Add to PATH and set PYTHONPATH
ENV PATH=/home/dagster/.local/bin:$PATH \
    PYTHONPATH=/opt/dagster/app

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python -c "import dagster; print('OK')" || exit 1

# Expose port for gRPC server
EXPOSE 4000

# Default command (overridden by Helm chart)
CMD ["dagster", "api", "grpc", "-h", "0.0.0.0", "-p", "4000", "-m", "dagster_weather.weather_pipeline"]
