# Open-Jev Container Image for OpenShift
# Multi-stage build for smaller production image
# =============================================================================
# Build stage: install dependencies and Open-Jev runtime
# =============================================================================
FROM python:3.11-slim AS builder

WORKDIR /app

# Install system dependencies needed for building
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Copy Open-Jev source code
COPY Open-Jev /app/Open-Jev

WORKDIR /app/Open-Jev

# Install Open-Jev in development mode with training extras
# This compiles any C extensions and installs all dependencies
RUN pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -e . && \
    pip install --no-cache-dir -e '.[train]'

# =============================================================================
# Runtime stage: minimal image with only runtime dependencies
# =============================================================================
FROM python:3.11-slim AS runtime

WORKDIR /app

# Install only runtime system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Copy installed packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy Open-Jev source code (needed for runtime imports)
COPY --from=builder /app/Open-Jev /app/Open-Jev

WORKDIR /app/Open-Jev

# Create non-root user for OpenShift security
RUN useradd -r -u 10001 -g 0 -d /app -s /sbin/nologin -c "Open-Jev User" openjev && \
    chown -R 10001:0 /app && \
    chmod -R g=u /app

# Expose the Open-Jev server port
EXPOSE 8791

# Switch to non-root user
USER 10001

# Default command - override with OpenShift deployment args
# The checkpoint path and device will be provided via deployment
CMD ["python", "-m", "jev.server", \
     "--checkpoint", "/models/Open-Jev-2B/package/checkpoint", \
     "--device", "cuda:0", \
     "--max-length", "4096", \
     "--batch-size", "1", \
     "--no-prefix-cache", \
     "--host", "0.0.0.0"]