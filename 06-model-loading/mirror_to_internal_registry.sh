#!/usr/bin/env bash
# =============================================================================
# Mirror Open-Jev Images to Internal Registry (Air-Gapped)
# =============================================================================
# This script mirrors the required container images to an internal registry
# for air-gapped OpenShift deployments.
#
# Prerequisites:
# - Connected machine with podman/docker and skopeo
# - Access to internal registry (with auth)
# - oc CLI with cluster-admin or image-stream permissions
#
# Usage:
#   ./mirror_to_internal_registry.sh <INTERNAL_REGISTRY> [--namespace jev-model]
# =============================================================================

set -euo pipefail

INTERNAL_REGISTRY="${1:-}"
NAMESPACE="${NAMESPACE:-jev-model}"

if [[ -z "$INTERNAL_REGISTRY" ]]; then
    echo "Usage: $0 <INTERNAL_REGISTRY> [--namespace jev-model]"
    echo "Example: $0 registry.internal.company.com/ai"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check tools
command -v skopeo >/dev/null 2>&1 || error "skopeo not found. Install: dnf install skopeo / apt install skopeo"
command -v oc >/dev/null 2>&1 || error "oc CLI not found"

# Images to mirror
declare -A IMAGES=(
    # Base builder image
    ["ubi9/python-311"]="registry.access.redhat.com/ubi9/python-311:latest"
    # Alternative: UBI minimal for smaller runtime
    ["ubi9-minimal"]="registry.access.redhat.com/ubi9/ubi-minimal:latest"
    # OpenShift CLI for debugging
    ["ocp-cli"]="registry.access.redhat.com/openshift4/ose-cli:latest"
    # Curl for testing
    ["curlimages/curl"]="curlimages/curl:latest"
)

# NVIDIA GPU Operator images (if needed)
# These are typically installed via OperatorHub, but can be mirrored if required
declare -A GPU_OPERATOR_IMAGES=(
    ["nvidia-driver"]="nvidia/driver:latest"
    ["nvidia-toolkit"]="nvidia/k8s-device-plugin:latest"
    ["nvidia-operator"]="nvidia/operator:latest"
    ["gpu-feature-discovery"]="nvidia/gpu-feature-discovery:latest"
    ["dcgm-exporter"]="nvidia/dcgm-exporter:latest"
    ["node-status-exporter"]="nvidia/node-status-exporter:latest"
)

mirror_image() {
    local name="$1"
    local source="$2"
    local target="${INTERNAL_REGISTRY}/${name}"
    
    log "Mirroring $name: $source -> $target"
    
    # Use skopeo for efficient mirroring
    skopeo copy --all \
        --src-tls-verify=false \
        --dest-tls-verify=false \
        "docker://${source}" \
        "docker://${target}" || {
        warn "Failed to mirror $name, trying with podman..."
        podman pull "$source" || error "Failed to pull $source"
        podman tag "$source" "$target"
        podman push --tls-verify=false "$target" || error "Failed to push $target"
    }
    
    success "Mirrored $name to $target"
}

# Mirror base images
log "=== Mirroring Base Images ==="
for name in "${!IMAGES[@]}"; do
    mirror_image "$name" "${IMAGES[$name]}"
done

# Mirror GPU Operator images (optional)
read -p "Mirror NVIDIA GPU Operator images? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "=== Mirroring NVIDIA GPU Operator Images ==="
    for name in "${!GPU_OPERATOR_IMAGES[@]}"; do
        mirror_image "gpu-operator/${name}" "${GPU_OPERATOR_IMAGES[$name]}"
    done
fi

# Create ImageContentSourcePolicy for OpenShift
log "=== Creating ImageContentSourcePolicy ==="
ICSP_FILE="/tmp/icsp-open-jev.yaml"
cat > "$ICSP_FILE" <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: open-jev-mirror
spec:
  repositoryDigestMirrors:
EOF

for name in "${!IMAGES[@]}"; do
    source="${IMAGES[$name]}"
    target="${INTERNAL_REGISTRY}/${name}"
    # Extract registry from source
    source_registry=$(echo "$source" | cut -d'/' -f1)
    cat >> "$ICSP_FILE" <<EOF
    - mirrors:
      - ${target}
      source: ${source}
EOF
done

log "ImageContentSourcePolicy created at $ICSP_FILE"
log "Apply with: oc apply -f $ICSP_FILE"
warn "ICSP requires cluster-admin and will cause a rolling reboot of worker nodes!"

# Create ImageStream for OpenShift to use internal registry
log "=== Creating ImageStream for Internal Registry ==="
IS_FILE="/tmp/imagestream-internal.yaml"
cat > "$IS_FILE" <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: open-jev
  namespace: $NAMESPACE
spec:
  lookupPolicy:
    local: true
  tags:
    - name: "2b"
      from:
        kind: DockerImage
        name: "${INTERNAL_REGISTRY}/open-jev:2b"
      importPolicy:
        scheduled: true
      referencePolicy:
        type: Local
    - name: "builder"
      from:
        kind: DockerImage
        name: "${INTERNAL_REGISTRY}/ubi9/python-311:latest"
      importPolicy:
        scheduled: true
      referencePolicy:
        type: Local
    - name: "cli"
      from:
        kind: DockerImage
        name: "${INTERNAL_REGISTRY}/ocp-cli:latest"
      importPolicy:
        scheduled: true
      referencePolicy:
        type: Local
EOF

log "ImageStream created at $IS_FILE"
log "Apply with: oc apply -f $IS_FILE -n $NAMESPACE"

# Update BuildConfig to use internal registry
log "=== BuildConfig Update Notes ==="
cat <<EOF

Update your BuildConfig (02-imagestream-buildconfig.yaml) to use internal registry:

strategy:
  dockerStrategy:
    from:
      kind: ImageStreamTag
      name: "builder:latest"  # Points to internal ubi9/python-311
      namespace: $NAMESPACE
    pullSecret:
      name: "internal-registry-pull-secret"  # Create this secret

output:
  to:
    kind: ImageStreamTag
    name: "open-jev:2b"

Create pull secret:
oc create secret docker-registry internal-registry-pull-secret \\
  --docker-server=$INTERNAL_REGISTRY \\
  --docker-username=<USERNAME> \\
  --docker-password=<PASSWORD> \\
  --docker-email=<EMAIL> \\
  -n $NAMESPACE

oc secrets link builder internal-registry-pull-secret --for=pull -n $NAMESPACE
oc secrets link default internal-registry-pull-secret --for=pull -n $NAMESPACE
EOF

success "Mirror preparation complete!"
log "Next steps:"
log "1. Apply ICSP: oc apply -f $ICSP_FILE (requires cluster-admin)"
log "2. Apply ImageStream: oc apply -f $IS_FILE -n $NAMESPACE"
log "3. Update BuildConfig to reference internal ImageStreams"
log "4. Create pull secret for internal registry"
log "5. Trigger build: oc start-build open-jev-build -n $NAMESPACE"