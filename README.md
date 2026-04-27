# Azure AKS GitOps Playbook

A production-realistic DevSecOps reference implementation deploying the [Google Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) (11 microservices) on Azure Kubernetes Service using GitOps, private networking, and shift-left security scanning.

Built as a learning playbook — every architectural decision is documented with the reasoning and trade-offs considered.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  GitHub                                                             │
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│  │ build-push   │    │terraform-dev │    │ dast.yml             │  │
│  │ secret-scan  │    │ checkov      │    │ OWASP ZAP            │  │
│  │ sast/sca     │    │ tfsec/tflint │    │ (post-deploy)        │  │
│  │ image-scan   │    │ plan→apply   │    └──────────────────────┘  │
│  └──────┬───────┘    └──────┬───────┘                              │
│         │                   │                                       │
└─────────┼───────────────────┼───────────────────────────────────────┘
          │ push images        │ provision infra
          ▼                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Azure (East US)                                                    │
│                                                                     │
│  ┌─── VNet 10.10.0.0/16 ─────────────────────────────────────────┐ │
│  │                                                                │ │
│  │  ┌─── AKS Subnet /24 ─────────┐  ┌─── PE Subnet /24 ───────┐ │ │
│  │  │                            │  │                          │ │ │
│  │  │  system pool (D2s_v3 ×1)   │  │  ACR private endpoint   │ │ │
│  │  │  user pool  (D4s_v3 ×2)    │  │  KV  private endpoint   │ │ │
│  │  │                            │  │                          │ │ │
│  │  │  ┌─────────┐  ┌─────────┐  │  └──────────────────────── ┘ │ │
│  │  │  │ ArgoCD  │  │Boutique │  │                              │ │
│  │  │  │         │  │  ×11    │  │  ┌─── Private DNS Zones ───┐ │ │
│  │  │  └────┬────┘  └─────────┘  │  │  privatelink.azurecr.io │ │ │
│  │  │       │ syncs from Git      │  │  privatelink.vault...   │ │ │
│  │  └───────┼────────────────────┘  └─────────────────────────┘ │ │
│  │          │                                                     │ │
│  └──────────┼─────────────────────────────────────────────────── ┘ │
│             │ watches                                               │
│  ┌──────────┘                                                       │
│  │  Azure Container Registry (boutiquedevacr)                       │
│  │  Azure Key Vault (boutique-dev-kv)                               │
│  │  Log Analytics Workspace (boutique-dev-law)                      │
│  │  Terraform state → Storage Account (tfstate3a2f7662)             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| Cloud | Azure (East US) | AKS, ACR, Key Vault, private networking |
| Container orchestration | AKS 1.29 — private cluster | No public API server endpoint |
| Image registry | ACR Basic (dev) | Private endpoint; AcrPull via managed identity |
| Secret store | Azure Key Vault | Private endpoint; no secrets in Git or manifests |
| GitOps | ArgoCD | Dev: auto-sync. Prod: manual gate |
| Config management | Kustomize | Base + overlays for dev/prod; no Helm overhead |
| IaC | Terraform 1.7 | Remote state in Azure Blob; modular design |
| CI — app | GitHub Actions | OIDC auth; no stored credentials |
| CI — infra | GitHub Actions | Checkov + tfsec + TFLint before every plan |
| Network policy | Calico | Pod-to-pod traffic locked down by policy |
| Image tags | `sha-<commit>` | Immutable; guarantees prod matches a specific commit |

---

## Security Controls

| Control | Implementation |
|---------|---------------|
| No long-lived credentials | OIDC federated identity for GitHub Actions (no client secret) |
| Private AKS API server | `private_cluster_enabled = true` — not reachable from internet |
| Private ACR | Private endpoint + DNS zone; pods pull via VNet |
| Private Key Vault | Private endpoint + `public_network_access_enabled = false` |
| Managed identity for image pull | AKS kubelet identity gets AcrPull — no username/password |
| IaC security gate | Checkov blocks HIGH findings before `terraform plan` runs |
| Secret leak detection | Gitleaks scans full git history on every PR |
| SAST | Semgrep: OWASP Top 10, Go, Python, JS, Java rules |
| SCA | Trivy: HIGH/CRITICAL CVEs in dependency manifests block build |
| Image scanning | Trivy: CRITICAL CVEs in container layers block deployment |
| DAST | OWASP ZAP baseline scan after ArgoCD syncs to dev |
| Prod deployment gate | ArgoCD manual sync + GitHub Environment required reviewer |
| No secrets in Git | All secrets in Azure Key Vault; mounted via CSI driver |
| NetworkPolicy | Calico enforces pod-to-pod traffic rules |

---

## Repository Structure

```
azure-aks-gitops/
├── .github/workflows/
│   ├── build-push.yml        ← App CI: secret-scan → SAST → SCA → build → image-scan
│   ├── terraform-dev.yml     ← Infra CI: Checkov → tfsec → TFLint → plan → apply
│   └── dast.yml              ← DAST: OWASP ZAP after deploy
├── .azuredevops/pipelines/   ← Azure DevOps equivalents (ADO variant)
├── infrastructure/terraform/
│   ├── modules/              ← networking, aks, acr, keyvault
│   └── environments/
│       ├── dev/              ← run terraform here for dev
│       └── prod/             ← run terraform here for prod
├── kubernetes/
│   ├── base/                 ← upstream manifests (all 11 services)
│   └── overlays/
│       ├── dev/              ← dev-specific resource quotas, image tags
│       └── prod/             ← prod replicas, HPA, PDB, resource quotas
├── gitops/argocd/
│   ├── install/              ← ArgoCD install kustomization
│   └── apps/                 ← ArgoCD Application manifests (dev + prod)
├── docs/
│   ├── implementation-guide.md  ← Full setup runbook with actual values
│   ├── system-design.md         ← Architecture decisions and trade-offs
│   └── ...
├── .gitignore
├── .dockerignore
└── .gitattributes
```

---

## Pipeline Flows

### App Pipeline (`build-push.yml`)

```
PR/push to main (src/** changed)
    │
    ├── secret-scan   Gitleaks — full git history
    ├── sast          Semgrep — OWASP Top 10 + language rules
    ├── sca           Trivy fs — HIGH/CRITICAL CVEs in dependencies
    │
    └── [all pass] → build-push → image-scan (×10 parallel) → update-tags
                                                                    │
                                                              ArgoCD detects
                                                              tag change → sync
                                                                    │
                                                             dast.yml triggers
                                                             (ZAP baseline scan)
```

### Infra Pipeline (`terraform-dev.yml`)

```
PR/push to main (infrastructure/terraform/** changed)
    │
    ├── security   Checkov (HIGH blocks) + tfsec (informational → Security tab)
    ├── validate   terraform fmt + terraform validate + TFLint
    │
    └── [all pass] → plan (output posted as PR comment)
                         │
                    [push to main only]
                         │
                    environment: dev ← requires manual approval in GitHub
                         │
                    terraform apply
```

---

## Prerequisites

| Tool | Install | Version |
|------|---------|---------|
| Azure CLI | [docs.microsoft.com](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | ≥ 2.85 |
| Terraform | [developer.hashicorp.com](https://developer.hashicorp.com/terraform/install) | ≥ 1.7 |
| kubectl | `az aks install-cli` | any recent |
| kustomize | [kubectl.kustomize.io](https://kubectl.kustomize.io) | any recent |
| Git | [git-scm.com](https://git-scm.com) | ≥ 2.40 |

---

## Getting Started

See [`docs/implementation-guide.md`](docs/implementation-guide.md) for the full step-by-step runbook with all provisioned values filled in.

### Quick summary

```bash
# 1. Bootstrap Terraform state storage
az group create --name tfstate-rg --location eastus
az storage account create --name tfstate3a2f7662 --resource-group tfstate-rg \
  --location eastus --sku Standard_LRS --allow-blob-public-access false

# 2. Init and plan infrastructure
cd infrastructure/terraform/environments/dev
terraform init
terraform plan   # review, then apply after approval

# 3. Bootstrap ArgoCD
az aks command invoke --resource-group boutique-dev-rg --name boutique-dev-aks \
  --command "kubectl create namespace argocd"
az aks command invoke --resource-group boutique-dev-rg --name boutique-dev-aks \
  --command "kubectl apply -k https://github.com/tushart-chaudhari1992/azure-aks-gitops/gitops/argocd/install"

# 4. Apply ArgoCD Application
az aks command invoke --resource-group boutique-dev-rg --name boutique-dev-aks \
  --command "kubectl apply -f https://raw.githubusercontent.com/tushart-chaudhari1992/azure-aks-gitops/main/gitops/argocd/apps/boutique-dev.yaml"
```

---

## Cost (dev environment, East US)

| Resource | ~Monthly |
|----------|---------|
| AKS nodes (1× D2s_v3 + 2× D4s_v3) | $350 |
| ACR Basic + private endpoint | $20 |
| Key Vault + private endpoint | $20 |
| Log Analytics (30-day retention) | $5 |
| Load Balancer | $20 |
| **Total** | **~$415/mo** |

Run `terraform destroy` when not actively using the cluster to avoid charges.

---

## Key Design Decisions

Full rationale for every decision is in [`docs/system-design.md`](docs/system-design.md).

- **Private cluster over public** — reduces attack surface; `az aks command invoke` provides dev access without VPN
- **Kustomize over Helm** — first-party manifests don't need Helm's templating overhead; overlays are simpler to review in GitOps PRs
- **OIDC over service principal secrets** — federated credentials expire and auto-rotate; no stored secrets in GitHub
- **Dev ACR public + private endpoint** — public access lets GitHub-hosted runners push; pods still pull via private endpoint only
- **Checkov blocks, tfsec informs** — Checkov has Azure-specific rules that catch real misconfigs; tfsec is used as a second opinion visible in the Security tab
