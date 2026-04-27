# Kubernetes Manifests — Improvement Report

Applied by the Claude Code Kubernetes Specialist skill on 2026-04-27.

---

## Summary

Seven gaps were identified and resolved across the base manifests and environment overlays:
four security gaps and three reliability gaps. All changes are in declarative YAML; no live
cluster changes were made. They take effect on the next ArgoCD sync.

---

## What Was Improved

### 1. Container-Level Security Context — All 11 Services

**Gap:** Every container had a pod-level `securityContext` (runAsNonRoot, runAsUser) but was
missing the container-level block that locks down Linux capabilities.

**Added to every container:**

```yaml
securityContext:
  allowPrivilegeEscalation: false   # blocks setuid/sudo escalation inside the container
  readOnlyRootFilesystem: true      # prevents in-container writes to the root fs
  capabilities:
    drop: ["ALL"]                   # removes all Linux capabilities (NET_RAW, SYS_ADMIN, etc.)
```

**Exception — `redis.yaml`:** Redis writes to `/data` (emptyDir volume), so
`readOnlyRootFilesystem: false` is intentional there. All other capabilities are still dropped.

**Why it matters:** Without `allowPrivilegeEscalation: false`, a compromised process could
re-escalate to root via setuid binaries that may exist in the base image. Without capability
dropping, `NET_RAW` (raw socket access for ARP spoofing) and other dangerous capabilities
remain available. These three fields together form the standard container hardening baseline
required by the CIS Kubernetes Benchmark and Azure Defender for Containers.

---

### 2. Dedicated ServiceAccounts — All 11 Services

**Gap:** `frontend.yaml` explicitly set `serviceAccountName: default`. All other deployments
inherited `default` silently. The default ServiceAccount exists in every namespace and can
accumulate RBAC permissions from other sources over time.

**Added:** `kubernetes/base/serviceaccounts.yaml` — one dedicated ServiceAccount per service
with `automountServiceAccountToken: false`.

```yaml
# example — same pattern for all 11 services
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: boutique
automountServiceAccountToken: false
```

Each deployment now references its own SA:
```yaml
serviceAccountName: frontend-sa
```

**Why it matters:** Using `default` SA means all pods share the same identity — if one pod
is compromised, an attacker can use its token to impersonate all other services.
`automountServiceAccountToken: false` prevents the token from being projected into the pod
unless explicitly needed (none of these services call the Kubernetes API). This satisfies the
least-privilege RBAC principle.

---

### 3. NetworkPolicies — Default-Deny + Per-Service Allow Rules

**Gap:** No NetworkPolicies existed. All pods could communicate freely with all other pods
in the namespace.

**Added:** `kubernetes/base/networkpolicies.yaml` — 14 policies total.

| Policy | Effect |
|--------|--------|
| `default-deny-all` | Blocks all ingress and egress across the namespace |
| `allow-dns-egress` | Allows UDP/TCP port 53 for kube-dns (all pods) |
| `allow-frontend` | Ingress from any (LoadBalancer); egress to 7 backends |
| `allow-productcatalogservice` | Ingress from frontend, checkoutservice, recommendationservice |
| `allow-currencyservice` | Ingress from frontend, checkoutservice |
| `allow-cartservice` | Ingress from frontend, checkoutservice; egress to redis-cart |
| `allow-redis-cart` | Ingress from cartservice only |
| `allow-recommendationservice` | Ingress from frontend; egress to productcatalogservice |
| `allow-shippingservice` | Ingress from frontend, checkoutservice |
| `allow-checkoutservice` | Ingress from frontend; egress to 6 downstream services |
| `allow-paymentservice` | Ingress from checkoutservice only |
| `allow-emailservice` | Ingress from checkoutservice only |
| `allow-adservice` | Ingress from frontend only |

**Service communication map the policies encode:**

```
LoadBalancer → frontend (8080)
frontend → productcatalogservice (3550), currencyservice (7000), cartservice (7070),
           recommendationservice (8080), shippingservice (50051), checkoutservice (5050),
           adservice (9555)
checkoutservice → productcatalogservice, shippingservice, paymentservice, emailservice,
                  currencyservice, cartservice
recommendationservice → productcatalogservice
cartservice → redis-cart (6379)
```

**Why it matters:** Without NetworkPolicies, a compromised `adservice` pod could directly
connect to `paymentservice` or `redis-cart` — services it has no legitimate reason to reach.
The default-deny approach enforces the principle of least network privilege: a pod can only
reach exactly the services it is designed to call.

---

### 4. `fsGroup` Added to All Pod Security Contexts

**Gap:** Pod-level `securityContext` was missing `fsGroup: 2000`.

**Added:**
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 2000      # added
```

**Why it matters:** When a container mounts a volume and runs as non-root, the volume's files
may be owned by root. `fsGroup` causes Kubernetes to `chown` mounted volumes to the specified
GID before the container starts, ensuring the non-root user can read/write files. Without it,
volume mounts silently fail or require world-writable permissions.

---

### 5. Explicit `periodSeconds` on Health Probes

**Gap:** Several services were missing `periodSeconds` on readiness and liveness probes
(frontend, cartservice, productcatalogservice, currencyservice, paymentservice,
shippingservice, checkoutservice).

**Added `periodSeconds: 10` to all missing probes.** Services that already had it
(emailservice: 5s, recommendationservice: 5s, adservice: 15s, redis: 5s) were left unchanged.

**Why it matters:** When `periodSeconds` is absent, Kubernetes silently defaults to 10s. Making
it explicit documents intent and prevents unexpected behaviour changes if the default ever
changes between Kubernetes versions.

---

### 6. PodDisruptionBudgets — Production Overlay

**Gap:** No PDBs existed. During AKS node upgrades or manual drains, Kubernetes could evict
all replicas of a service simultaneously, causing full downtime.

**Added:** `kubernetes/overlays/prod/pdb.yaml`

| Service | minAvailable | Reason |
|---------|-------------|--------|
| frontend | 2 | 3 replicas in prod; always keep 2 serving |
| checkoutservice | 1 | 2 replicas; checkout must never go to zero |
| cartservice | 1 | 2 replicas; cart loss = lost orders |
| paymentservice | 1 | 2 replicas (new HPA); payment must stay available |

**Why it matters:** AKS node pool upgrades drain nodes one at a time. Without PDBs, a 2-replica
deployment can have both pods evicted from the same drain operation in quick succession. PDBs
force the upgrade to wait until a replacement pod is healthy before proceeding to the next eviction.

---

### 7. Additional HPAs — cartservice and paymentservice

**Gap:** Only `frontend` and `checkoutservice` had HPAs. `cartservice` is on every page load
and checkout path; `paymentservice` processes real transactions. Both needed auto-scaling.

**Added to `kubernetes/overlays/prod/hpa.yaml`:**

| HPA | minReplicas | maxReplicas | CPU target |
|-----|------------|------------|-----------|
| cartservice-hpa | 2 | 8 | 60% |
| paymentservice-hpa | 2 | 4 | 60% |

**Why it matters:** Under traffic spikes, `cartservice` becomes the bottleneck between the
frontend and Redis. Without HPA it stays at 2 replicas regardless of load. `paymentservice`
is capped at max 4 because it calls external payment APIs where over-scaling can trigger rate
limits or duplicate charges.

---

### 8. ResourceQuota + LimitRange — Both Environments

**Gap:** No namespace-level guardrails existed. A misconfigured deployment could consume all
node CPU/memory, starving other services.

**Added:**
- `kubernetes/overlays/prod/resourcequota.yaml`
- `kubernetes/overlays/dev/resourcequota.yaml`

**Prod limits:**

| Resource | Request ceiling | Limit ceiling |
|---------|----------------|--------------|
| CPU | 4 cores | 8 cores |
| Memory | 4 Gi | 8 Gi |
| Pods | 50 | — |
| Services | 20 | — |

**Dev limits:** half of prod (2 cores request / 4 cores limit, 2 Gi / 4 Gi).

**LimitRange defaults (both environments):** ensures any pod without explicit resource
requests still gets `100m CPU / 64Mi` request and `200m CPU / 128Mi` limit — matching
the existing per-service settings.

**Why it matters:** ResourceQuota prevents a misconfigured or runaway deployment from
consuming all cluster resources. LimitRange ensures that even `kubectl run` one-off pods
(common during debugging) get bounded resources automatically.

---

## Files Changed

### Modified (11 existing base manifests)

| File | Changes |
|------|---------|
| `base/frontend.yaml` | SA ref, fsGroup, container securityContext, probe periodSeconds |
| `base/cartservice.yaml` | SA ref, fsGroup, container securityContext, readiness periodSeconds |
| `base/redis.yaml` | SA ref, fsGroup, container securityContext (readOnlyRootFilesystem: false) |
| `base/productcatalogservice.yaml` | SA ref, fsGroup, container securityContext, probe periodSeconds |
| `base/currencyservice.yaml` | SA ref, fsGroup, container securityContext, probe periodSeconds |
| `base/paymentservice.yaml` | SA ref, fsGroup, container securityContext, probe periodSeconds |
| `base/shippingservice.yaml` | SA ref, fsGroup, container securityContext, probe periodSeconds |
| `base/emailservice.yaml` | SA ref, fsGroup, container securityContext |
| `base/checkoutservice.yaml` | SA ref, fsGroup, container securityContext, probe periodSeconds |
| `base/recommendationservice.yaml` | SA ref, fsGroup, container securityContext |
| `base/adservice.yaml` | SA ref, fsGroup, container securityContext |

### Modified (existing overlay/config files)

| File | Changes |
|------|---------|
| `base/kustomization.yaml` | Added serviceaccounts.yaml, networkpolicies.yaml |
| `overlays/prod/kustomization.yaml` | Added pdb.yaml, resourcequota.yaml |
| `overlays/dev/kustomization.yaml` | Added resourcequota.yaml |
| `overlays/prod/hpa.yaml` | Added cartservice-hpa, paymentservice-hpa |

### Created (5 new files)

| File | Purpose |
|------|---------|
| `base/serviceaccounts.yaml` | 11 dedicated ServiceAccounts, one per service |
| `base/networkpolicies.yaml` | default-deny + 13 explicit allow rules |
| `overlays/prod/pdb.yaml` | PDBs for frontend, checkout, cart, payment |
| `overlays/prod/resourcequota.yaml` | ResourceQuota + LimitRange for boutique-prod |
| `overlays/dev/resourcequota.yaml` | ResourceQuota + LimitRange for boutique-dev |

---

## What Difference the Kubernetes Specialist Skill Makes

Without the skill, a reviewer doing a manual pass typically catches visible issues: missing
resource limits, absent probes, obvious misconfigurations. The specialist skill closes the
gap between "it runs" and "it is secure":

| Area | Without skill | With skill |
|------|--------------|-----------|
| **Security surface** | Containers run with full capability set; any pod can network to any other pod | All Linux capabilities dropped; network segmented to exact service-to-service paths |
| **Identity** | Every pod shares the `default` ServiceAccount; one compromise exposes all | Each service has its own identity; `automountServiceAccountToken: false` prevents API access |
| **Blast radius** | A compromised `adservice` can reach `paymentservice` or `redis-cart` directly | NetworkPolicies enforce that `adservice` can only receive from `frontend`; outbound is blocked |
| **Cluster upgrade safety** | Node drain can evict all replicas simultaneously | PDBs guarantee minimum pod count during evictions |
| **Noisy neighbour** | One misconfigured pod can exhaust namespace CPU/memory | ResourceQuota caps consumption; LimitRange applies defaults automatically |
| **Auto-scaling coverage** | Two services scale; nine do not | Four services scale (added cart, payment) covering the full critical checkout path |
| **Probe determinism** | Silent Kubernetes default (10s) on some probes | All probes have explicit `periodSeconds` — no implicit defaults |

The skill encodes the CIS Kubernetes Benchmark, OWASP Kubernetes Security Cheat Sheet, and
Azure Defender for Containers recommendations as a structured checklist applied consistently
across all manifests — catching gaps that are easy to miss service-by-service in a manual review.
