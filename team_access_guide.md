# Team Access Guide: Open-Jev Inference API

## Quick Start for Team Members

Once deployed, your team can access the Open-Jev API at:

```
🔗 External URL: https://open-jev-team.apps.<YOUR_CLUSTER_DOMAIN>
🔗 Internal URL: http://open-jev.jev-model.svc.cluster.local:8791
```

## Authentication

The API uses **OpenShift OAuth** for authentication. Access options:

### Option 1: Service Account Token (for applications/services)

```bash
# Create a service account for your application
oc create sa my-app -n my-team-namespace

# Get token
TOKEN=$(oc create token my-app -n my-team-namespace --duration=24h)

# Use in requests
curl -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -X POST https://open-jev-team.apps.<CLUSTER_DOMAIN>/predict \
     -d '{"state": "...", "questions": {...}}'
```

### Option 2: User Token (for interactive use)

```bash
# Get your user token
TOKEN=$(oc whoami -t)

# Use in requests
curl -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -X POST https://open-jev-team.apps.<CLUSTER_DOMAIN>/predict \
     -d '{"state": "...", "questions": {...}}'
```

### Option 3: API Key (if 3scale/API Gateway configured)

```bash
# Get API key from 3scale developer portal
API_KEY="your-api-key-here"

curl -H "Authorization: Bearer $API_KEY" \
     -H "Content-Type: application/json" \
     -X POST https://open-jev-team.apps.<CLUSTER_DOMAIN>/predict \
     -d '{"state": "...", "questions": {...}}'
```

## API Reference

### Health Check

```bash
curl https://open-jev-team.apps.<CLUSTER_DOMAIN>/health
```

Response:
```json
{"status": "healthy", "model": "open-jev-2b", "gpu": "NVIDIA A100"}
```

### Inference Endpoint

**POST** `/predict` or `/infer`

#### Request Format

```json
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
```

#### Response Format

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

### Multiple Questions

```json
{
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
}
```

Response:
```json
{
  "predictions": {
    "severity": {
      "probabilities": {"critical": 0.05, "high": 0.75, "medium": 0.18, "low": 0.02},
      "predicted_label": "high"
    },
    "team": {
      "probabilities": {"identity": 0.88, "platform": 0.08, "support": 0.04},
      "predicted_label": "identity"
    }
  }
}
```

## Python Client Example

```python
import requests
import os

class OpenJevClient:
    def __init__(self, base_url: str, token: str = None):
        self.base_url = base_url.rstrip('/')
        self.session = requests.Session()
        if token:
            self.session.headers.update({"Authorization": f"Bearer {token}"})
        self.session.headers.update({"Content-Type": "application/json"})

    def health(self) -> dict:
        return self.session.get(f"{self.base_url}/health", timeout=10).json()

    def predict(self, state: str, questions: dict) -> dict:
        payload = {"state": state, "questions": questions}
        resp = self.session.post(f"{self.base_url}/predict", json=payload, timeout=120)
        resp.raise_for_status()
        return resp.json()

# Usage
client = OpenJevClient(
    base_url="https://open-jev-team.apps.<CLUSTER_DOMAIN>",
    token=os.environ.get("OC_TOKEN")  # or pass directly
)

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
```

## JavaScript/TypeScript Client

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
    private baseUrl: string,
    private token?: string
  ) {}

  private headers(): HeadersInit {
    const h: HeadersInit = { "Content-Type": "application/json" };
    if (this.token) h["Authorization"] = `Bearer ${this.token}`;
    return h;
  }

  async health(): Promise<any> {
    const res = await fetch(`${this.baseUrl}/health`, { headers: this.headers() });
    return res.json();
  }

  async predict(request: OpenJevRequest): Promise<OpenJevResponse> {
    const res = await fetch(`${this.baseUrl}/predict`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(request),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
    return res.json();
  }
}

// Usage
const client = new OpenJevClient(
  "https://open-jev-team.apps.<CLUSTER_DOMAIN>",
  import.meta.env.VITE_OC_TOKEN
);

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

## Rate Limits

| Tier | Requests/Minute | Burst |
|------|-----------------|-------|
| Default (team) | 60 | 10 |
| High-volume (request via admin) | 300 | 50 |

Exceeding limits returns `429 Too Many Requests` with `Retry-After` header.

## Monitoring & Dashboards

- **Grafana**: Search "Open-Jev 2B Inference Dashboard"
- **Metrics**: `http_requests_total`, `http_request_duration_seconds`, `container_cpu_usage_seconds_total`
- **Alerts**: Configured for GPU OOM, high latency (>5s), error rate >5%

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `401 Unauthorized` | Refresh token: `oc whoami -t` or recreate SA token |
| `429 Rate Limited` | Implement exponential backoff, request higher quota |
| `504 Gateway Timeout` | Request too complex; reduce `max_length` or simplify criteria |
| `503 Service Unavailable` | Pod scaling up; retry with backoff |
| GPU OOM in logs | Reduce `batch_size` or `max_length` in deployment |

## Support

- **Slack**: #open-jev-support
- **Email**: ai-platform-team@company.com
- **Docs**: https://open-jev-team.apps.<CLUSTER_DOMAIN>/docs
- **Issues**: GitHub Issues in internal repo

## Example Use Cases

1. **Ticket Routing** → Auto-route support tickets to correct team
2. **Severity Classification** → Prioritize incidents automatically
3. **Feature Triage** → Classify feature requests by product area
4. **Code Review Assignment** → Route PRs to domain experts
5. **Compliance Checking** → Flag requests needing legal review

---

*Deployed with Open-Jev 2B on OpenShift | GPU: NVIDIA A100 | Namespace: jev-model*