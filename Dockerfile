# Open-Jev Container Image for OpenShift
# Multi-stage build for smaller production image
# Uses Red Hat UBI Python images (no Docker Hub rate limits)
# =============================================================================
# Build stage: install dependencies and Open-Jev runtime (runs as root)
# =============================================================================
FROM registry.access.redhat.com/ubi9/python-311:latest AS builder

# Switch to root for package installation
USER root

WORKDIR /app

# Install system dependencies needed for building
RUN dnf install -y --setopt=install_weak_deps=False \
    git \
    gcc \
    gcc-c++ \
    && dnf clean all

# Copy Open-Jev source code
COPY Open-Jev /app/Open-Jev

WORKDIR /app/Open-Jev

# Install Open-Jev in development mode with training extras
# This compiles any C extensions and installs all dependencies
# Use pip install --target to control install location
RUN pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -e . && \
    pip install --no-cache-dir -e '.[train]'

# Find and copy site-packages to a known location for multi-stage copy
RUN python3 -c "import site; print(site.getsitepackages()[0])" > /site-packages-path.txt && \
    cp -r $(cat /site-packages-path.txt) /site-packages

# =============================================================================
# Runtime stage: minimal image with only runtime dependencies
# =============================================================================
FROM registry.access.redhat.com/ubi9/python-311:latest AS runtime

# Switch to root for package installation
USER root

WORKDIR /app

# Install only runtime system dependencies
RUN dnf install -y --setopt=install_weak_deps=False \
    libgomp \
    && dnf clean all

# Copy installed packages from builder (from known location)
COPY --from=builder /site-packages /usr/local/lib/python3.11/site-packages
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