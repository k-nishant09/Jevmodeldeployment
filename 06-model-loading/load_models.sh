#!/usr/bin/env bash
# =============================================================================
# Air-Gapped Model Loading Script for Open-Jev on OpenShift
# =============================================================================
# This script downloads Open-Jev and Qwen models on a connected machine,
# packages them, and provides procedures to load them onto the OpenShift PVC.
#
# Prerequisites:
# - Connected machine with internet access
# - huggingface_hub installed: pip install huggingface_hub[hf_transfer]
# - oc CLI configured for target OpenShift cluster
# - ~50GB free disk space
#
# Usage:
#   ./load_models.sh [--stage download|package|upload] [--namespace jev-model]
# =============================================================================

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-jev-model}"
PVC_NAME="${PVC_NAME:-jev-model-pvc}"
MODEL_DIR="${MODEL_DIR:-./models}"
STAGING_DIR="${STAGING_DIR:-./staging}"
UPLOAD_POD="${UPLOAD_POD:-model-loader}"

# Model revisions (pinned for reproducibility)
QWEN_MODEL="Qwen/Qwen3.5-2B"
QWEN_REVISION="15852e8c16360a2fea060d615a32b45270f8a8fc"
OPEN_JEV_MODEL="ZefanCai/Open-Jev-2B"
OPEN_JEV_REVISION="0c7aa498b1627be8da4acf34c863ff0ee0a92785"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check prerequisites
check_prereqs() {
    log "Checking prerequisites..."
    command -v hf >/dev/null 2>&1 || error "huggingface_hub CLI not found. Install: pip install huggingface_hub[hf_transfer]"
    command -v oc >/dev/null 2>&1 || error "oc CLI not found"
    command -v tar >/dev/null 2>&1 || error "tar not found"
    
    # Check oc login
    oc whoami >/dev/null 2>&1 || error "Not logged into OpenShift. Run: oc login <API_URL>"
    
    # Check namespace exists
    oc get namespace "$NAMESPACE" >/dev/null 2>&1 || error "Namespace '$NAMESPACE' does not exist"
    
    # Check PVC exists
    oc get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || error "PVC '$PVC_NAME' not found in namespace '$NAMESPACE'"
    
    success "Prerequisites check passed"
}

# Stage 1: Download models from Hugging Face
stage_download() {
    log "=== STAGE 1: Downloading models from Hugging Face ==="
    
    mkdir -p "$MODEL_DIR"
    
    # Enable HF transfer for faster downloads
    export HF_HUB_ENABLE_HF_TRANSFER=1
    
    log "Downloading Qwen base model: $QWEN_MODEL @ $QWEN_REVISION"
    hf download "$QWEN_MODEL" \
        --revision "$QWEN_REVISION" \
        --local-dir "$MODEL_DIR/Qwen3.5-2B" \
        --local-dir-use-symlinks False
    
    log "Downloading Open-Jev adapter: $OPEN_JEV_MODEL @ $OPEN_JEV_REVISION"
    hf download "$OPEN_JEV_MODEL" \
        --revision "$OPEN_JEV_REVISION" \
        --local-dir "$MODEL_DIR/Open-Jev-2B" \
        --local-dir-use-symlinks False
    
    success "Models downloaded to $MODEL_DIR"
    
    # Verify structure
    log "Verifying model structure..."
    if [[ ! -d "$MODEL_DIR/Qwen3.5-2B" ]]; then
        error "Qwen model directory not found"
    fi
    if [[ ! -d "$MODEL_DIR/Open-Jev-2B" ]]; then
        error "Open-Jev model directory not found"
    fi
    
    # Check for checkpoint directory
    if [[ ! -d "$MODEL_DIR/Open-Jev-2B/package/checkpoint" ]]; then
        warn "Checkpoint directory not at expected path. Checking alternatives..."
        find "$MODEL_DIR/Open-Jev-2B" -name "checkpoint" -type d | head -5
    fi
    
    success "Model structure verified"
}

# Stage 2: Package models for transfer
stage_package() {
    log "=== STAGE 2: Packaging models for transfer ==="
    
    mkdir -p "$STAGING_DIR"
    
    # Create tarballs for each model
    log "Creating Qwen model tarball..."
    tar -czf "$STAGING_DIR/qwen-model.tar.gz" -C "$MODEL_DIR" Qwen3.5-2B
    
    log "Creating Open-Jev model tarball..."
    tar -czf "$STAGING_DIR/open-jev-model.tar.gz" -C "$MODEL_DIR" Open-Jev-2B
    
    # Create manifest
    cat > "$STAGING_DIR/MANIFEST.txt" <<EOF
Open-Jev Model Package Manifest
Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Namespace: $NAMESPACE
PVC: $PVC_NAME

Models:
- Qwen3.5-2B (revision: $QWEN_REVISION)
- Open-Jev-2B (revision: $OPEN_JEV_REVISION)

Expected PVC structure after extraction:
/models/
├── Qwen3.5-2B/
│   ├── config.json
│   ├── model.safetensors (or pytorch_model.bin)
│   ├── tokenizer.json
│   ├── tokenizer_config.json
│   └── ...
└── Open-Jev-2B/
    └── package/
        └── checkpoint/
            ├── adapter_model.safetensors
            ├── adapter_config.json
            ├── head.safetensors
            ├── calibration.json
            └── ...

File sizes:
EOF
    
    du -h "$STAGING_DIR"/*.tar.gz >> "$STAGING_DIR/MANIFEST.txt"
    
    log "Package contents:"
    ls -lh "$STAGING_DIR/"
    
    success "Models packaged in $STAGING_DIR"
    log "Transfer $STAGING_DIR to your air-gapped environment"
}

# Stage 3: Upload to OpenShift PVC
stage_upload() {
    log "=== STAGE 3: Uploading models to OpenShift PVC ==="
    
    # Check if staging directory exists
    if [[ ! -d "$STAGING_DIR" ]]; then
        error "Staging directory $STAGING_DIR not found. Run with --stage package first."
    fi
    
    if [[ ! -f "$STAGING_DIR/qwen-model.tar.gz" ]] || [[ ! -f "$STAGING_DIR/open-jev-model.tar.gz" ]]; then
        error "Model tarballs not found in $STAGING_DIR"
    fi
    
    log "Starting upload pod..."
    oc run "$UPLOAD_POD" \
        -n "$NAMESPACE" \
        --image=registry.access.redhat.com/ubi9/python-311 \
        --overrides='{
            "spec": {
                "containers": [{
                    "name": "model-loader",
                    "image": "registry.access.redhat.com/ubi9/python-311",
                    "command": ["/bin/bash", "-c", "sleep 7200"],
                    "volumeMounts": [{
                        "name": "model-storage",
                        "mountPath": "/models"
                    }],
                    "resources": {
                        "requests": {"cpu": "1", "memory": "2Gi"},
                        "limits": {"cpu": "2", "memory": "4Gi"}
                    }
                }],
                "volumes": [{
                    "name": "model-storage",
                    "persistentVolumeClaim": {"claimName": "'$PVC_NAME'"}
                }],
                "serviceAccountName": "open-jev-sa",
                "securityContext": {
                    "runAsNonRoot": true,
                    "runAsUser": 10001,
                    "fsGroup": 0
                }
            }
        }' \
        --restart=Never \
        --command -- sleep 7200
    
    log "Waiting for upload pod to be ready..."
    oc wait --for=condition=Ready pod/"$UPLOAD_POD" -n "$NAMESPACE" --timeout=120s
    
    log "Copying Qwen model tarball to pod..."
    oc cp "$STAGING_DIR/qwen-model.tar.gz" "$NAMESPACE/$UPLOAD_POD:/tmp/qwen-model.tar.gz"
    
    log "Copying Open-Jev model tarball to pod..."
    oc cp "$STAGING_DIR/open-jev-model.tar.gz" "$NAMESPACE/$UPLOAD_POD:/tmp/open-jev-model.tar.gz"
    
    log "Extracting models on PVC..."
    oc exec -n "$NAMESPACE" "$UPLOAD_POD" -- /bin/bash -c "
        set -euo pipefail
        cd /models
        echo 'Extracting Qwen model...'
        tar -xzf /tmp/qwen-model.tar.gz
        echo 'Extracting Open-Jev model...'
        tar -xzf /tmp/open-jev-model.tar.gz
        echo 'Verifying structure...'
        ls -la /models/
        ls -la /models/Qwen3.5-2B/
        ls -la /models/Open-Jev-2B/package/checkpoint/ 2>/dev/null || echo 'Checkpoint path may differ'
        echo 'Cleanup...'
        rm /tmp/*.tar.gz
        echo 'Done.'
    "
    
    log "Cleaning up upload pod..."
    oc delete pod "$UPLOAD_POD" -n "$NAMESPACE" --ignore-not-found=true --wait=false
    
    success "Models uploaded to PVC '$PVC_NAME' in namespace '$NAMESPACE'"
}

# Stage 4: Verify models on PVC
stage_verify() {
    log "=== STAGE 4: Verifying models on PVC ==="
    
    # Create a verification pod
    VERIFY_POD="model-verify-$(date +%s)"
    
    log "Starting verification pod..."
    oc run "$VERIFY_POD" \
        -n "$NAMESPACE" \
        --image=registry.access.redhat.com/ubi9/python-311 \
        --overrides='{
            "spec": {
                "containers": [{
                    "name": "verify",
                    "image": "registry.access.redhat.com/ubi9/python-311",
                    "command": ["/bin/bash", "-c", "sleep 300"],
                    "volumeMounts": [{
                        "name": "model-storage",
                        "mountPath": "/models"
                    }]
                }],
                "volumes": [{
                    "name": "model-storage",
                    "persistentVolumeClaim": {"claimName": "'$PVC_NAME'"}
                }],
                "restartPolicy": "Never"
            }
        }' \
        --restart=Never \
        --command -- sleep 300
    
    oc wait --for=condition=Ready pod/"$VERIFY_POD" -n "$NAMESPACE" --timeout=60s
    
    log "Checking model structure on PVC..."
    oc exec -n "$NAMESPACE" "$VERIFY_POD" -- /bin/bash -c "
        echo '=== PVC Contents ==='
        find /models -type f -name '*.json' -o -name '*.safetensors' -o -name '*.bin' | head -30
        echo ''
        echo '=== Directory Structure ==='
        tree /models 2>/dev/null || find /models -type d | sort
        echo ''
        echo '=== Key Files ==='
        ls -lh /models/Qwen3.5-2B/config.json 2>/dev/null || echo 'Qwen config not found'
        ls -lh /models/Open-Jev-2B/package/checkpoint/ 2>/dev/null || echo 'Open-Jev checkpoint not found at expected path'
    "
    
    oc delete pod "$VERIFY_POD" -n "$NAMESPACE" --ignore-not-found=true --wait=false
    
    success "Verification complete"
}

# Main script logic
STAGE="${1:-all}"
case "$STAGE" in
    --stage=download|download)
        check_prereqs
        stage_download
        ;;
    --stage=package|package)
        check_prereqs
        stage_package
        ;;
    --stage=upload|upload)
        check_prereqs
        stage_upload
        ;;
    --stage=verify|verify)
        check_prereqs
        stage_verify
        ;;
    --stage=all|all|"")
        check_prereqs
        stage_download
        stage_package
        stage_upload
        stage_verify
        ;;
    *)
        echo "Usage: $0 [--stage download|package|upload|verify|all] [--namespace jev-model]"
        echo ""
        echo "Stages:"
        echo "  download  - Download models from Hugging Face (requires internet)"
        echo "  package   - Create tarballs for air-gap transfer"
        echo "  upload    - Upload tarballs to OpenShift PVC"
        echo "  verify    - Verify models on PVC"
        echo "  all       - Run all stages (default)"
        exit 1
        ;;
esac