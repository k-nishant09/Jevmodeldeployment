#!/usr/bin/env bash
# =============================================================================
# Test Open-Jev Inference on OpenShift
# =============================================================================
# This script validates the Open-Jev deployment by running inference tests
# Uses static Bearer token authentication (configured via AUTH_TOKEN env var or --token)
#
# Usage:
#   ./07-test-inference.sh [--namespace jev-model] [--route] [--external] [--token TOKEN]
#
# BEFORE RUNNING: Set AUTH_TOKEN environment variable or use --token flag
# export AUTH_TOKEN="your-static-token-here"
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-jev-model}"
USE_ROUTE="${USE_ROUTE:-false}"
EXTERNAL="${EXTERNAL:-false}"
# Default token - OVERRIDE WITH --token FLAG OR AUTH_TOKEN ENV VAR
AUTH_TOKEN="${AUTH_TOKEN:-REPLACE_WITH_YOUR_STATIC_TOKEN}"

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
        --token)
            AUTH_TOKEN="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate token is set
if [[ "$AUTH_TOKEN" == "REPLACE_WITH_YOUR_STATIC_TOKEN" ]]; then
    error "AUTH_TOKEN not set! Use --token YOUR_TOKEN or export AUTH_TOKEN=YOUR_TOKEN"
fi

# Determine endpoint
if [[ "$EXTERNAL" == "true" ]]; then
    ROUTE_HOST=$(oc get route open-jev -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [[ -z "$ROUTE_HOST" ]]; then
        error "Route not found. Deploy route first or use internal service."
    fi
    ENDPOINT="https://${ROUTE_HOST}"
    log "Using external route: $ENDPOINT"
elif [[ "$USE_ROUTE" == "true" ]]; then
    ROUTE_HOST=$(oc get route open-jev-gateway -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [[ -z "$ROUTE_HOST" ]]; then
        ROUTE_HOST=$(oc get route open-jev -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    fi
    if [[ -z "$ROUTE_HOST" ]]; then
        error "Route not found. Deploy route first or use internal service."
    fi
    ENDPOINT="https://${ROUTE_HOST}"
    log "Using gateway route: $ENDPOINT"
else
    ENDPOINT="http://open-jev.${NAMESPACE}.svc.cluster.local:8080"
    log "Using internal service (via auth-proxy): $ENDPOINT"
fi

# Common curl headers with static token auth
CURL_AUTH=(-H "Authorization: Bearer ${AUTH_TOKEN}" -H "Content-Type: application/json")

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
oc logs -n "$NAMESPACE" "$POD" -c open-jev --tail=50

# Test 1: Health endpoint (no auth required for health)
log "=== Test 1: Health Check ==="
if curl -sfk --max-time 10 "${ENDPOINT}/health" >/dev/null 2>&1; then
    success "Health endpoint responding"
    curl -sk "${ENDPOINT}/health" | jq . 2>/dev/null || curl -sk "${ENDPOINT}/health"
else
    warn "Health endpoint not responding, trying root..."
    if curl -sfk --max-time 10 "${ENDPOINT}/" >/dev/null 2>&1; then
        success "Root endpoint responding"
        curl -sk "${ENDPOINT}/" | jq . 2>/dev/null || curl -sk "${ENDPOINT}/"
    else
        error "No response from Open-Jev server"
    fi
fi

# Test 2: Inference test with static token auth
log "=== Test 2: Inference Test (with Bearer token: ${AUTH_TOKEN}) ==="

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

log "Sending inference request to /v1/predict..."
RESPONSE=$(curl -sk -X POST \
    "${CURL_AUTH[@]}" \
    -d @/tmp/test-request.json \
    --max-time 60 \
    "${ENDPOINT}/v1/predict" 2>/dev/null)

if [[ -z "$RESPONSE" ]]; then
    log "Trying /predict endpoint..."
    RESPONSE=$(curl -sk -X POST \
        "${CURL_AUTH[@]}" \
        -d @/tmp/test-request.json \
        --max-time 60 \
        "${ENDPOINT}/predict" 2>/dev/null)
fi

if [[ -z "$RESPONSE" ]]; then
    log "Trying /infer endpoint..."
    RESPONSE=$(curl -sk -X POST \
        "${CURL_AUTH[@]}" \
        -d @/tmp/test-request.json \
        --max-time 60 \
        "${ENDPOINT}/infer" 2>/dev/null)
fi

if [[ -z "$RESPONSE" ]]; then
    log "Trying /v1/infer endpoint..."
    RESPONSE=$(curl -sk -X POST \
        "${CURL_AUTH[@]}" \
        -d @/tmp/test-request.json \
        --max-time 60 \
        "${ENDPOINT}/v1/infer" 2>/dev/null)
fi

if [[ -n "$RESPONSE" ]]; then
    success "Inference response received"
    echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
else
    warn "No response from inference endpoint. Trying alternative endpoints..."
    
    # Try to discover API endpoints
    log "Discovering API endpoints..."
    curl -sk "${ENDPOINT}/docs" 2>/dev/null | head -20 || true
    curl -sk "${ENDPOINT}/openapi.json" 2>/dev/null | jq '.paths | keys[]' 2>/dev/null || true
    curl -sk "${ENDPOINT}/" 2>/dev/null | jq . 2>/dev/null || true
fi

# Test 3: Test with /v1/models endpoint (OpenAI-compatible)
log "=== Test 3: Models Endpoint (/v1/models) ==="
MODELS_RESPONSE=$(curl -sk -X GET \
    "${CURL_AUTH[@]}" \
    --max-time 10 \
    "${ENDPOINT}/v1/models" 2>/dev/null)
if [[ -n "$MODELS_RESPONSE" ]]; then
    success "Models endpoint responding"
    echo "$MODELS_RESPONSE" | jq . 2>/dev/null || echo "$MODELS_RESPONSE"
else
    warn "Models endpoint not available (may need to be implemented in Open-Jev)"
fi

# Test 4: GPU utilization check
log "=== Test 4: GPU Utilization ==="
oc exec -n "$NAMESPACE" "$POD" -c open-jev -- nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null || warn "nvidia-smi not available in container"

# Test 5: Resource usage
log "=== Test 5: Resource Usage ==="
oc describe pod "$POD" -n "$NAMESPACE" | grep -A 10 "Limits:\|Requests:"

# Test 6: Latency benchmark (optional)
if [[ "${BENCHMARK:-false}" == "true" ]]; then
    log "=== Test 6: Latency Benchmark (10 requests) ==="
    for i in {1..10}; do
        START=$(date +%s%N)
        curl -sk -X POST \
            "${CURL_AUTH[@]}" \
            -d @/tmp/test-request.json \
            --max-time 60 \
            "${ENDPOINT}/v1/predict" >/dev/null 2>&1 || true
        END=$(date +%s%N)
        LATENCY_MS=$(( (END - START) / 1000000 ))
        echo "Request $i: ${LATENCY_MS}ms"
    done
fi

# Cleanup
rm -f /tmp/test-request.json

success "Inference testing complete!"
log "Next steps:"
log "  - Monitor GPU memory: oc exec -n $NAMESPACE $POD -c open-jev -- nvidia-smi -l 1"
log "  - Check logs: oc logs -f -n $NAMESPACE deployment/open-jev -c open-jev"
log "  - Scale up: oc scale deployment open-jev --replicas=2 -n $NAMESPACE"
log "  - Run benchmark: BENCHMARK=true ./07-test-inference.sh"
log ""
log "Gateway endpoints for team consumption (replace <YOUR_CLUSTER_DOMAIN>):"
log "  - https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>/v1/predict"
log "  - https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>/v1/models"
log "  - Auth: Bearer token = \$AUTH_TOKEN (set via --token or env var)"