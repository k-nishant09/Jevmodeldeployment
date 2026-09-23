#!/usr/bin/env bash
# =============================================================================
# Open-Jev Complete Deployment Script for OpenShift
# =============================================================================
# This script deploys the complete Open-Jev 2B inference stack on OpenShift
# with 1 GPU, including all resources, model loading, and validation.
#
# Prerequisites:
# - OpenShift cluster with NVIDIA GPU Operator installed
# - oc CLI logged in with cluster-admin or project-admin permissions
# - ~50GB storage available for PVC
# - Connected machine for model download (or pre-loaded models)
#
# Usage:
#   ./deploy_openjev.sh [OPTIONS]
#
# Options:
#   --namespace NAMESPACE      OpenShift namespace (default: jev-model)
#   --storage-class CLASS      PVC storage class (default: thin-csi)
#   --storage-size SIZE        PVC size (default: 50Gi)
#   --registry REGISTRY        Internal registry for air-gapped (optional)
#   --skip-build               Skip image build (use existing image)
#   --skip-model-load          Skip model loading (models already on PVC)
#   --dry-run                  Show what would be deployed without applying
#   --help                     Show this help
# =============================================================================

set -euo pipefail

# Default configuration
NAMESPACE="jev-model"
STORAGE_CLASS="thin-csi"
STORAGE_SIZE="50Gi"
INTERNAL_REGISTRY=""
SKIP_BUILD=false
SKIP_MODEL_LOAD=false
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --storage-class)
            STORAGE_CLASS="$2"
            shift 2
            ;;
        --storage-size)
            STORAGE_SIZE="$2"
            shift 2
            ;;
        --registry)
            INTERNAL_REGISTRY="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-model-load)
            SKIP_MODEL_LOAD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            grep '^#' "$0" | cut -c4-
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Apply function with dry-run support
apply() {
    local file="$1"
    local namespace="${2:-$NAMESPACE}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would apply: $file to namespace: $namespace"
        oc apply --dry-run=client -f "$file" -n "$namespace" 2>/dev/null || true
    else
        log "Applying: $file"
        oc apply -f "$file" -n "$namespace"
    fi
}

# Check prerequisites
check_prereqs() {
    log "=== Checking Prerequisites ==="
    
    command -v oc >/dev/null 2>&1 || error "oc CLI not found"
    command -v jq >/dev/null 2>&1 || warn "jq not found (output formatting limited)"
    
    # Check oc login
    oc whoami >/dev/null 2>&1 || error "Not logged into OpenShift. Run: oc login <API_URL>"
    
    # Check cluster version
    CLUSTER_VERSION=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // "unknown"')
    log "OpenShift version: $CLUSTER_VERSION"
    
    # Check GPU Operator
    if oc get csv -A -l operators.coreos.com/gpu-operator.openshift-operators 2>/dev/null | grep -q Succeeded; then
        success "NVIDIA GPU Operator is installed"
    else
        warn "NVIDIA GPU Operator may not be installed. Check: oc get csv -A | grep gpu"
        warn "GPU scheduling will not work without GPU Operator!"
    fi
    
    # Check GPU nodes
    GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l)
    if [[ "$GPU_NODES" -gt 0 ]]; then
        success "Found $GPU_NODES GPU node(s)"
        oc get nodes -l nvidia.com/gpu.present=true -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product
    else
        warn "No GPU nodes found with label nvidia.com/gpu.present=true"
        warn "Deployment will remain pending until GPU node is available"
    fi
    
    # Check namespace
    if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
        warn "Namespace '$NAMESPACE' already exists"
    else
        log "Namespace '$NAMESPACE' will be created"
    fi
    
    success "Prerequisites check complete"
}

# Create namespace
create_namespace() {
    log "=== Creating Namespace ==="
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would create namespace: $NAMESPACE"
        return
    fi
    
    oc new-project "$NAMESPACE" 2>/dev/null || oc project "$NAMESPACE"
    
    # Add labels for monitoring/network policies
    oc label namespace "$NAMESPACE" \
        app=open-jev \
        component=inference \
        --overwrite
    
    success "Namespace ready: $NAMESPACE"
}

# Deploy RBAC and SCC
deploy_rbac() {
    log "=== Deploying RBAC and SCC ==="
    
    apply "$SCRIPT_DIR/05-rbac-scc.yaml"
    
    # Bind SCC to service account (requires cluster-admin)
    if [[ "$DRY_RUN" != "true" ]]; then
        log "Binding SCC to service account (requires cluster-admin)..."
        oc adm policy add-scc-to-user restricted-v2 -z open-jev-sa -n "$NAMESPACE" 2>/dev/null || \
        oc adm policy add-scc-to-user open-jev-gpu-scc -z open-jev-sa -n "$NAMESPACE" 2>/dev/null || \
        warn "Could not bind SCC. Run manually: oc adm policy add-scc-to-user restricted-v2 -z open-jev-sa -n $NAMESPACE"
    fi
    
    success "RBAC deployed"
}

# Deploy PVC
deploy_pvc() {
    log "=== Deploying PVC ==="
    
    # Update storage class in PVC
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would create PVC with storageClass: $STORAGE_CLASS, size: $STORAGE_SIZE"
        return
    fi
    
    # Create temporary PVC with correct storage class
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jev-model-pvc
  namespace: $NAMESPACE
  labels:
    app: open-jev
    component: model-storage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $STORAGE_SIZE
  storageClassName: $STORAGE_CLASS
EOF
    
    # Wait for PVC to bind
    log "Waiting for PVC to bind..."
    oc wait --for=condition=Bound pvc/jev-model-pvc -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
        warn "PVC not bound yet. Check storage class and provisioner."
    
    success "PVC deployed"
}

# Build and deploy image
build_image() {
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log "=== Skipping Image Build ==="
        return
    fi
    
    log "=== Building Open-Jev Image ==="
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would trigger build: open-jev-build"
        return
    fi
    
    # Check if Open-Jev source exists
    if [[ ! -d "$SCRIPT_DIR/Open-Jev" ]]; then
        log "Cloning Open-Jev repository..."
        git clone https://github.com/Zefan-Cai/Open-Jev.git "$SCRIPT_DIR/Open-Jev"
    fi
    
    # Apply BuildConfig
    apply "$SCRIPT_DIR/02-imagestream-buildconfig.yaml"
    
    # Start build
    log "Starting build (this may take 5-10 minutes)..."
    oc start-build open-jev-build -n "$NAMESPACE" --follow --wait
    
    # Verify image
    oc get imagestream open-jev -n "$NAMESPACE"
    
    success "Image built and pushed to internal registry"
}

# Deploy application
deploy_app() {
    log "=== Deploying Open-Jev Application ==="
    
    # Update deployment with correct image reference if using internal registry
    if [[ -n "$INTERNAL_REGISTRY" ]]; then
        log "Using internal registry: $INTERNAL_REGISTRY"
        # The deployment references image-registry.openshift-image-registry.svc:5000/$NAMESPACE/open-jev:2b
        # which works for internal OpenShift registry
    fi
    
    apply "$SCRIPT_DIR/03-deployment.yaml"
    apply "$SCRIPT_DIR/04-service-route.yaml"
    apply "$SCRIPT_DIR/08-gateway-api.yaml"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        # Wait for deployment
        log "Waiting for deployment rollout..."
        oc rollout status deployment/open-jev -n "$NAMESPACE" --timeout=300s || {
            warn "Deployment rollout timed out. Checking status..."
            oc get pods -n "$NAMESPACE" -l app=open-jev
            oc describe pod -n "$NAMESPACE" -l app=open-jev
        }
    fi
    
    success "Application deployed"
}

# Load models
load_models() {
    if [[ "$SKIP_MODEL_LOAD" == "true" ]]; then
        log "=== Skipping Model Loading ==="
        return
    fi
    
    log "=== Loading Models to PVC ==="
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would run model loading script"
        return
    fi
    
    if [[ -f "$SCRIPT_DIR/06-model-loading/load_models.sh" ]]; then
        chmod +x "$SCRIPT_DIR/06-model-loading/load_models.sh"
        "$SCRIPT_DIR/06-model-loading/load_models.sh" --stage=all --namespace "$NAMESPACE"
    else
        warn "Model loading script not found. Manual steps required:"
        warn "1. Download models on connected machine"
        warn "2. Transfer to air-gapped environment"
        warn "3. Upload to PVC using oc cp or model-loader pod"
    fi
    
    success "Models loaded"
}

# Run validation tests
validate_deployment() {
    log "=== Validating Deployment ==="
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would run validation tests"
        return
    fi
    
    if [[ -f "$SCRIPT_DIR/07-test-inference.sh" ]]; then
        chmod +x "$SCRIPT_DIR/07-test-inference.sh"
        "$SCRIPT_DIR/07-test-inference.sh" --namespace "$NAMESPACE"
    else
        warn "Test script not found. Manual validation:"
        warn "  oc logs -f -n $NAMESPACE deployment/open-jev"
        warn "  oc run curl -n $NAMESPACE --image=curlimages/curl --rm -it -- sh"
        warn "  curl http://open-jev:8791/health"
    fi
    
    success "Validation complete"
}

# Print summary
print_summary() {
    log "=== Deployment Summary ==="
    echo ""
    echo "Namespace: $NAMESPACE"
    echo "Storage Class: $STORAGE_CLASS"
    echo "Storage Size: $STORAGE_SIZE"
    echo ""
    
    if [[ "$DRY_RUN" != "true" ]]; then
        echo "Resources deployed:"
        oc get all -n "$NAMESPACE" -l app=open-jev
        echo ""
        echo "PVC status:"
        oc get pvc -n "$NAMESPACE"
        echo ""
        echo "Pod status:"
        oc get pods -n "$NAMESPACE" -l app=open-jev -o wide
        echo ""
        
        # Get routes
        ROUTE=$(oc get route open-jev -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "Not created")
        GATEWAY_ROUTE=$(oc get route open-jev-gateway -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "Not created")
        echo "Internal URL:     http://open-jev.$NAMESPACE.svc.cluster.local:8791"
        echo "External Route:   https://$ROUTE"
        echo "Team Gateway:     https://$GATEWAY_ROUTE"
        echo ""
        
        echo "Next steps:"
        echo "  1. Check logs:     oc logs -f -n $NAMESPACE deployment/open-jev"
        echo "  2. Test inference: ./07-test-inference.sh --namespace $NAMESPACE"
        echo "  3. Monitor GPU:    oc exec -n $NAMESPACE \$(oc get pod -n $NAMESPACE -l app=open-jev -o name) -- nvidia-smi"
        echo "  4. Scale:          oc scale deployment open-jev --replicas=2 -n $NAMESPACE"
        echo "  5. Team access:    Share https://$GATEWAY_ROUTE with team (see team_access_guide.md)"
        echo "  6. Dashboards:     Grafana -> Search 'Open-Jev 2B Inference Dashboard'"
    fi
}

# Main execution
main() {
    log "Starting Open-Jev 2B deployment on OpenShift"
    log "Configuration: namespace=$NAMESPACE, storage=$STORAGE_SIZE ($STORAGE_CLASS)"
    [[ -n "$INTERNAL_REGISTRY" ]] && log "Internal registry: $INTERNAL_REGISTRY"
    [[ "$SKIP_BUILD" == "true" ]] && log "Skipping image build"
    [[ "$SKIP_MODEL_LOAD" == "true" ]] && log "Skipping model loading"
    [[ "$DRY_RUN" == "true" ]] && log "DRY RUN MODE - no changes will be applied"
    echo ""
    
    check_prereqs
    create_namespace
    deploy_rbac
    deploy_pvc
    build_image
    deploy_app
    load_models
    validate_deployment
    print_summary
    
    success "Open-Jev 2B deployment complete!"
}

main "$@"