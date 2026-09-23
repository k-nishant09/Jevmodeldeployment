#!/usr/bin/env bash
# =============================================================================
# Test Open-Jev Inference on OpenShift
# =============================================================================
# This script validates the Open-Jev deployment by running inference tests
#
# Usage:
#   ./07-test-inference.sh [--namespace jev-model] [--route] [--external]
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-jev-model}"
USE_ROUTE="${USE_ROUTE:-false}"
EXTERNAL="${EXTERNAL:-false}"

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

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --route)
            USE_ROUTE=true
            shift
            ;;
        --external)
            EXTERNAL=true
            USE_ROUTE=true
            shift
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Determine endpoint
if [[ "$EXTERNAL" == "true" ]]; then
    ROUTE_HOST=$(oc get route open-jev -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [[ -z "$ROUTE_HOST" ]]; then
        error "Route not found. Deploy route first or use internal service."
    fi
    ENDPOINT="https://${ROUTE_HOST}"
    log "Using external route: $ENDPOINT"
elif [[ "$USE_ROUTE" == "true" ]]; then
    ROUTE_HOST=$(oc get route open-jev -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [[ -z "$ROUTE_HOST" ]]; then
        error "Route not found. Deploy route first or use internal service."
    fi
    ENDPOINT="http://${ROUTE_HOST}"
    log "Using internal route: $ENDPOINT"
else
    ENDPOINT="http://open-jev.${NAMESPACE}.svc.cluster.local:8791"
    log "Using internal service: $ENDPOINT"
fi

# Wait for deployment to be ready
log "Waiting for Open-Jev deployment to be ready..."
oc rollout status deployment/open-jev -n "$NAMESPACE" --timeout=300s

# Get pod name
POD=$(oc get pods -n "$NAMESPACE" -l app=open-jev -o jsonpath='{.items[0].metadata.name}')
if [[ -z "$POD" ]]; then
    error "No Open-Jev pods found"
fi
log "Testing pod: $POD"

# Check pod logs for model loading
log "Checking pod logs for model loading status..."
oc logs -n "$NAMESPACE" "$POD" --tail=50

# Test 1: Health endpoint
log "=== Test 1: Health Check ==="
if curl -sf --max-time 10 "${ENDPOINT}/health" >/dev/null 2>&1; then
    success "Health endpoint responding"
    curl -s "${ENDPOINT}/health" | jq . 2>/dev/null || curl -s "${ENDPOINT}/health"
else
    warn "Health endpoint not responding, trying root..."
    if curl -sf --max-time 10 "${ENDPOINT}/" >/dev/null 2>&1; then
        success "Root endpoint responding"
        curl -s "${ENDPOINT}/" | jq . 2>/dev/null || curl -s "${ENDPOINT}/"
    else
        error "No response from Open-Jev server"
    fi
fi

# Test 2: Inference test
log "=== Test 2: Inference Test ==="

# Sample request matching Open-Jev format
cat > /tmp/test-request.json <<'EOF'
{
  "state": "The customer order arrived damaged and the customer is requesting a full refund.",
  "questions": {
    "route": {
      "type": "choice",
      "instructions": "Which team should handle this customer issue?",
      "criteria": {
        "billing": "Refunds, charges, and payment issues",
        "support": "General customer inquiries and complaints",
        "engineering": "Software defects and technical bugs",
        "shipping": "Delivery and logistics problems"
      }
    }
  }
}
EOF

log "Sending inference request..."
RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d @/tmp/test-request.json \
    --max-time 60 \
    "${ENDPOINT}/predict" 2>/dev/null || curl -s -X POST \
    -H "Content-Type: application/json" \
    -d @/tmp/test-request.json \
    --max-time 60 \
    "${ENDPOINT}/infer" 2>/dev/null || curl -s -X POST \
    -H "Content-Type: application/json" \
    -d @/tmp/test-request.json \
    --max-time 60 \
    "${ENDPOINT}/v1/predict" 2>/dev/null)

if [[ -n "$RESPONSE" ]]; then
    success "Inference response received"
    echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
else
    warn "No response from inference endpoint. Trying alternative endpoints..."
    
    # Try to discover API endpoints
    log "Discovering API endpoints..."
    curl -s "${ENDPOINT}/docs" 2>/dev/null | head -20 || true
    curl -s "${ENDPOINT}/openapi.json" 2>/dev/null | jq '.paths | keys[]' 2>/dev/null || true
    curl -s "${ENDPOINT}/" 2>/dev/null | jq . 2>/dev/null || true
fi

# Test 3: GPU utilization check
log "=== Test 3: GPU Utilization ==="
oc exec -n "$NAMESPACE" "$POD" -- nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null || warn "nvidia-smi not available in container"

# Test 4: Resource usage
log "=== Test 4: Resource Usage ==="
oc describe pod "$POD" -n "$NAMESPACE" | grep -A 10 "Limits:\|Requests:"

# Test 5: Latency benchmark (optional)
if [[ "${BENCHMARK:-false}" == "true" ]]; then
    log "=== Test 5: Latency Benchmark (10 requests) ==="
    for i in {1..10}; do
        START=$(date +%s%N)
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d @/tmp/test-request.json \
            --max-time 60 \
            "${ENDPOINT}/predict" >/dev/null 2>&1 || true
        END=$(date +%s%N)
        LATENCY_MS=$(( (END - START) / 1000000 ))
        echo "Request $i: ${LATENCY_MS}ms"
    done
fi

# Cleanup
rm -f /tmp/test-request.json

success "Inference testing complete!"
log "Next steps:"
log "  - Monitor GPU memory: oc exec -n $NAMESPACE $POD -- nvidia-smi -l 1"
log "  - Check logs: oc logs -f -n $NAMESPACE deployment/open-jev"
log "  - Scale up: oc scale deployment open-jev --replicas=2 -n $NAMESPACE"
log "  - Run benchmark: BENCHMARK=true ./07-test-inference.sh"