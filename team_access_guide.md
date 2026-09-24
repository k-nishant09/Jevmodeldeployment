# Team Access Guide: Open-Jev Inference API

## Quick Start for Team Members

Once deployed, your team can access the Open-Jev API at:

```
🔗 Team Gateway (HTTPS): https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>
🔗 Internal Service:     http://open-jev.jev-model.svc.cluster.local:8080
```

**REPLACE `<YOUR_CLUSTER_DOMAIN>` with your OpenShift cluster domain** (e.g., `example.com`)

---

## Authentication

**Static Bearer Token**: Configured via Kubernetes Secret `open-jev-auth`

The token value is stored in the secret `open-jev-auth` in the `jev-model` namespace. 
All API requests (except `/health` and `/v1/health`) require the `Authorization: Bearer <TOKEN>` header.

### Create the Auth Secret (Run Once Before Deploy)

```bash
# Generate a secure cookie secret
COOKIE_SECRET=$(openssl rand -base64 32)

# Create the secret with your static token
oc create secret generic open-jev-auth -n jev-model \
  --from-literal=static-client-secret="YOUR_STATIC_TOKEN_HERE" \
  --from-literal=cookie-secret="$COOKIE_SECRET"

# Verify
oc get secret open-jev-auth -n jev-model -o yaml
```

---

## API Reference

### Health Check (No Auth Required)
```bash
curl -k https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>/health
```

**Response:**
```json
{
  "status": "healthy",
  "model": "open-jev-2b",
  "gpu": "NVIDIA A100",
  "version": "2b"
}
```

---

### Inference Endpoint

**POST** `/v1/predict` (preferred) or `/predict`

```bash
curl -k -X POST https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>/v1/predict \
  -H "Authorization: Bearer YOUR_STATIC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
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
  }'
```

**Response:**
```json
{
  "predictions": {
    "route": {
      "probabilities": {
        "billing": 0.92,
        "support": 0.05,
        "engineering": 0.02,
        "shipping": 0.01
      },
      "predicted_label": "billing",
      "confidence": 0.92
    }
  },
  "metadata": {
    "model": "open-jev-2b",
    "latency_ms": 145,
    "tokens_processed": 87
  }
}
```

---

### Models Endpoint (OpenAI-Compatible)

**GET** `/v1/models`

```bash
curl -k -X GET https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>/v1/models \
  -H "Authorization: Bearer YOUR_STATIC_TOKEN"
```

**Response:**
```json
{
  "object": "list",
  "data": [
    {
      "id": "open-jev-2b",
      "object": "model",
      "owned_by": "open-jev",
      "permission": []
    }
  ]
}
```

---

### Multiple Questions (Single Request)

```bash
curl -k -X POST https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>/v1/predict \
  -H "Authorization: Bearer YOUR_STATIC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "state": "Customer reports login failure after password reset.",
    "questions": {
      "severity": {
        "type": "choice",
        "instructions": "Classify severity",
        "criteria": {
          "critical": "System down, data loss, security breach",
          "high": "Major feature broken, many users affected",
          "medium": "Minor feature issue, workaround exists",
          "low": "Cosmetic, enhancement request"
        }
      },
      "team": {
        "type": "choice",
        "instructions": "Route to team",
        "criteria": {
          "identity": "Authentication, authorization, SSO",
          "platform": "Core platform, infrastructure",
          "support": "General customer support"
        }
      }
    }
  }'
```

**Response:**
```json
{
  "predictions": {
    "severity": {
      "probabilities": {"critical": 0.05, "high": 0.75, "medium": 0.18, "low": 0.02},
      "predicted_label": "high",
      "confidence": 0.75
    },
    "team": {
      "probabilities": {"identity": 0.88, "platform": 0.08, "support": 0.04},
      "predicted_label": "identity",
      "confidence": 0.88
    }
  }
}
```

---

## Client Libraries

### Python

```python
import requests
import os

class OpenJevClient:
    def __init__(self, base_url: str = "https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>", token: str = None):
        self.base_url = base_url.rstrip('/')
        self.token = token or os.environ.get("OPEN_JEV_TOKEN")
        if not self.token:
            raise ValueError("Token required: set OPEN_JEV_TOKEN env var or pass token parameter")
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json"
        })
        # Disable SSL verify for self-signed certs (remove in production with valid certs)
        self.session.verify = False

    def health(self) -> dict:
        return self.session.get(f"{self.base_url}/health", timeout=10).json()

    def predict(self, state: str, questions: dict) -> dict:
        payload = {"state": state, "questions": questions}
        resp = self.session.post(f"{self.base_url}/v1/predict", json=payload, timeout=120)
        resp.raise_for_status()
        return resp.json()

    def models(self) -> dict:
        resp = self.session.get(f"{self.base_url}/v1/models", timeout=10)
        resp.raise_for_status()
        return resp.json()

# Usage
# export OPEN_JEV_TOKEN="your-static-token"
client = OpenJevClient()

# Check health
print(client.health())

# Single decision
result = client.predict(
    state="Customer wants refund for damaged item",
    questions={
        "route": {
            "type": "choice",
            "instructions": "Route to team",
            "criteria": {
                "billing": "Refunds and charges",
                "support": "General inquiries"
            }
        }
    }
)
print(f"Decision: {result['predictions']['route']['predicted_label']}")
print(f"Confidence: {result['predictions']['route']['confidence']:.2%}")

# List models
print(client.models())
```

### TypeScript/JavaScript

```typescript
interface OpenJevRequest {
  state: string;
  questions: Record<string, {
    type: "choice";
    instructions: string;
    criteria: Record<string, string>;
  }>;
}

interface OpenJevResponse {
  predictions: Record<string, {
    probabilities: Record<string, number>;
    predicted_label: string;
    confidence: number;
  }>;
  metadata?: { model: string; latency_ms: number };
}

class OpenJevClient {
  constructor(
    private baseUrl: string = "https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>",
    private token: string = process.env.OPEN_JEV_TOKEN || ""
  ) {
    if (!this.token) {
      throw new Error("Token required: set OPEN_JEV_TOKEN env var");
    }
  }

  private headers(): HeadersInit {
    return {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${this.token}`
    };
  }

  async health(): Promise<any> {
    const res = await fetch(`${this.baseUrl}/health`, { headers: this.headers() });
    return res.json();
  }

  async predict(request: OpenJevRequest): Promise<OpenJevResponse> {
    const res = await fetch(`${this.baseUrl}/v1/predict`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(request),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
    return res.json();
  }

  async models(): Promise<any> {
    const res = await fetch(`${this.baseUrl}/v1/models`, { headers: this.headers() });
    return res.json();
  }
}

// Usage
// export OPEN_JEV_TOKEN="your-static-token"
const client = new OpenJevClient();

const result = await client.predict({
  state: "Server returning 500 errors on checkout",
  questions: {
    severity: {
      type: "choice",
      instructions: "Classify",
      criteria: { critical: "Data loss/downtime", high: "Major feature broken" }
    }
  }
});
console.log(result.predictions.severity.predicted_label);
```

### cURL Examples (Copy-Paste Ready)

```bash
# Set your token
export TOKEN="your-static-token-here"
export DOMAIN="your-cluster-domain"  # e.g., apps.example.com

# Health check
curl -k https://open-jev-team.apps.${DOMAIN}/health

# Inference
curl -k -X POST https://open-jev-team.apps.${DOMAIN}/v1/predict \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"state": "Your context here", "questions": {"q1": {"type": "choice", "instructions": "Choose", "criteria": {"a": "Option A", "b": "Option B"}}}}'

# Models
curl -k -X GET https://open-jev-team.apps.${DOMAIN}/v1/models \
  -H "Authorization: Bearer ${TOKEN}"
```

---

## Rate Limits

| Tier | Requests/Minute | Burst |
|------|-----------------|-------|
| Default | 60 | 10 |
| High-Volume | 300 | 50 (request via admin) |

Exceeding limits returns `429 Too Many Requests` with `Retry-After` header.

---

## Endpoint Summary Card

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    OPEN-JEV 2B GATEWAY                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│  Base URL:    https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>              │
│  Health:      GET  /health                    (no auth)                     │
│  Inference:   POST /v1/predict                (Bearer: <YOUR_TOKEN>)        │
│  Models:      GET  /v1/models                 (Bearer: <YOUR_TOKEN>)        │
│  Alt Predict: POST /predict                   (Bearer: <YOUR_TOKEN>)        │
│                                                                              │
│  Auth:        Authorization: Bearer <YOUR_STATIC_TOKEN>                     │
│  Rate Limit:  60 req/min default                                             │
│  Timeout:     120s                                                           │
│  TLS:         Edge termination (router handles TLS)                         │
│                                                                              │
│  Request Format:                                                             │
│  {                                                                           │
│    "state": "string - context for decision",                                │
│    "questions": {                                                            │
│      "<question_id>": {                                                     │
│        "type": "choice",                                                    │
│        "instructions": "string",                                            │
│        "criteria": { "<label>": "description" }                             │
│      }                                                                       │
│    }                                                                         │
│  }                                                                           │
│                                                                              │
│  Response Format:                                                            │
│  {                                                                           │
│    "predictions": {                                                          │
│      "<question_id>": {                                                     │
│        "probabilities": { "<label>": float },                               │
│        "predicted_label": "string",                                         │
│        "confidence": float                                                   │
│      }                                                                       │
│    },                                                                        │
│    "metadata": { "model": "open-jev-2b", "latency_ms": int }                │
│  }                                                                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Cross-Cluster Consumption

For teams on different clusters:

1. **Network**: Ensure destination cluster can reach `open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>` on port 443
2. **DNS**: Must resolve the gateway hostname
3. **Auth**: Use the static token in Authorization header

```bash
# From any cluster with network access
curl -k -X POST https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>/v1/predict \
  -H "Authorization: Bearer YOUR_STATIC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"state": "...", "questions": {...}}'
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `401 Unauthorized` | Check token: `Authorization: Bearer YOUR_STATIC_TOKEN` |
| `429 Rate Limited` | Implement exponential backoff, request higher quota |
| `504 Gateway Timeout` | Request too complex; reduce `max_length` or simplify criteria |
| `503 Service Unavailable` | Pod scaling up; retry with backoff |
| SSL Certificate Error | Use `-k` flag with curl, or add cluster CA to trust store |

---

## Support

- **Gateway URL**: https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>
- **Auth Token**: Stored in secret `open-jev-auth` (key: `static-client-secret`)
- **Internal Service**: http://open-jev.jev-model.svc.cluster.local:8080
- **Namespace**: `jev-model`
- **Model**: Open-Jev 2B (Qwen3.5-2B base + LoRA adapter)