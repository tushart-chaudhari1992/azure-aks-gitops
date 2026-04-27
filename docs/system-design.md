
# System Design: Azure AKS GitOps Platform

## What We Are Building

A production-grade container platform on Azure that runs a microservices application (Google Online Boutique), provisions all infrastructure through code, and deploys application changes automatically using GitOps. Every layer — from cloud resources to container images to Kubernetes workloads — is declared in version-controlled files and reconciled continuously.

---

## System Design Principles

### 1. Infrastructure as Code (IaC)
Every Azure resource is declared in Terraform. No resource is created manually through the portal. This makes infrastructure auditable, repeatable, and destroyable — the same environment can be re-created from scratch in minutes.

**Impact:** All changes go through code review. Drift between actual and declared state is visible and correctable. Onboarding is a `terraform apply`, not a runbook.

### 2. Immutable Infrastructure
Container images are built once, tagged with the Git SHA, pushed to a registry, and never modified after deployment. If a change is needed, a new image is built and deployed.

**Impact:** Rollback is instant — point to the previous image tag. Debugging is reliable — the image in production is exactly what was tested. No "it works on my machine" scenarios.

### 3. GitOps (Declarative, Pull-Based Delivery)
The desired state of every Kubernetes workload is stored in Git. ArgoCD continuously compares Git state to cluster state and reconciles any differences. CI pipelines do not push to the cluster — they push to Git.

**Impact:** Git becomes the single source of truth for what runs in the cluster. Audit trail is built in. Cluster access is not required for deployments — reducing blast radius of compromised CI credentials.

### 4. Separation of Concerns
Infrastructure provisioning (Terraform), application packaging (CI), and application delivery (ArgoCD) are three independent pipelines with clean boundaries. A change in one does not require changes in another.

**Impact:** Teams can own layers independently. Infrastructure changes do not block application deployments and vice versa.

### 5. Environment Parity
Dev and prod environments are provisioned from the same Terraform modules with different variable files. Kubernetes manifests share a common base and use Kustomize overlays for environment-specific values.

**Impact:** Bugs caught in dev are representative of prod behavior. Promoting to prod is a config change, not a re-architecture.

---

## Architecture Overview

```
Developer
    │
    ├── pushes code ──────────────────────────────────────────────────┐
    │                                                                  │
    ▼                                                                  ▼
GitHub Repository                                          Azure DevOps Repository
    │                                                                  │
    ├── GitHub Actions (CI)                          Azure Pipelines (Infra CI)
    │   ├── Build Docker images                          ├── terraform init
    │   ├── Push to ACR (tagged with Git SHA)            ├── terraform plan
    │   └── Update image tag in gitops/                  └── terraform apply (on approval)
    │              │
    │              ▼
    │         gitops/argocd/apps/   ◄─── ArgoCD watches this directory
    │                                           │
    ▼                                           ▼
Azure Container Registry (ACR)         AKS Cluster
    │                                  ├── argocd namespace
    └── Images pulled by AKS           ├── boutique namespace (dev)
                                       └── boutique namespace (prod)
```

**Data flow for a new deployment:**
1. Developer merges a PR to `main`
2. GitHub Actions builds a new image and pushes it to ACR with tag `sha-<commit>`
3. GitHub Actions updates the image tag in `gitops/argocd/apps/boutique-dev.yaml`
4. ArgoCD detects the change in Git and pulls the new manifest
5. AKS pulls the new image from ACR and rolls out the update

---

## Component Selection

### Application: Google Online Boutique

**What it is:** An 11-service e-commerce demo application maintained by Google. Services are written in Go, Python, Node.js, Java, and C#. Services communicate over gRPC internally and HTTP at the frontend.

**Why chosen over alternatives:**
| Alternative | Reason not chosen |
|-------------|-------------------|
| Sock Shop (Weaveworks) | Older tech stack, less actively maintained |
| Podinfo | Single service — doesn't demonstrate inter-service complexity |
| Custom app | Would require building, not the goal of this playbook |

**System design impact:** gRPC between services means we need a service mesh or at minimum proper DNS resolution within the cluster. The polyglot nature tests that our CI pipeline handles multiple language build contexts. The 11-service topology exercises Kubernetes networking, resource limits, and namespace isolation realistically.

---

### Cloud Provider: Microsoft Azure

**What it is:** The cloud platform hosting all infrastructure.

**Why chosen over alternatives:**
| Alternative | Reason not chosen |
|-------------|-------------------|
| AWS (EKS) | Already covered in the parallel AWS playbook in this repo |
| GCP (GKE) | Online Boutique originates from GCP — using Azure shows cloud portability |

**System design impact:** Azure-specific services (ACR, AKS managed identity, Key Vault) are used, but the Kubernetes and GitOps layers are cloud-agnostic. This demonstrates portability — the same manifests and ArgoCD config would work on any cluster.

---

### Infrastructure Provisioning: Terraform

**What it is:** HashiCorp's IaC tool using the AzureRM provider to declare and manage Azure resources.

**Why chosen over alternatives:**
| Alternative | Reason not chosen |
|-------------|-------------------|
| Azure Bicep | Azure-only — Terraform modules are reusable across clouds |
| ARM Templates | Verbose JSON with poor readability and no module ecosystem |
| Pulumi | Code-based IaC adds a programming language dependency; HCL is simpler for infra-only teams |

**System design impact:** Remote state is stored in Azure Blob Storage with state locking via lease acquisition — preventing concurrent applies from corrupting state. Modules are split by concern (networking, AKS, ACR, Key Vault) so teams can own and version them independently. Environment-specific values are isolated in `environments/dev` and `environments/prod` — the same module code runs both.

**Security impact:** A dedicated Service Principal with the minimum required RBAC roles is used by CI (not a personal account). State files may contain sensitive values — the Blob Storage container uses private access, versioning, and soft delete.

---

### Container Orchestration: Azure Kubernetes Service (AKS)

**What it is:** Azure's managed Kubernetes service. The control plane (API server, etcd, scheduler) is managed by Azure. We provision and manage node pools.

**Why chosen over alternatives:**
| Alternative | Reason not chosen |
|-------------|-------------------|
| Azure Container Apps | Abstracts away Kubernetes — less control, less educational for a DevOps playbook |
| Azure App Service (containers) | Not suited for multi-service workloads with service-to-service traffic |
| Self-managed Kubernetes on VMs | Operational burden of managing control plane is not the goal |

**System design impact:** AKS uses a system node pool (for cluster components) and a user node pool (for application workloads) — this prevents application pods from starving cluster-critical pods. Managed identity is used instead of service principal credentials for AKS to pull from ACR — no secrets to rotate. The cluster uses private networking: nodes are on a private subnet, and the API server endpoint is restricted.

**Security impact:** RBAC is enabled. Azure AD integration allows authenticating to the cluster with Azure identities rather than static kubeconfig credentials. Node OS disks are encrypted. Network Policy (Calico) is enabled to restrict pod-to-pod traffic to only what is declared.

---

### Container Registry: Azure Container Registry (ACR)

**What it is:** Azure's managed container image registry.

**Why chosen over alternatives:**
| Alternative | Reason not chosen |
|-------------|-------------------|
| Docker Hub | Public by default, rate-limited on free tier, not integrated with Azure RBAC |
| GitHub Container Registry (GHCR) | Works, but adds a cross-cloud dependency for an Azure-native setup |
| Self-hosted Harbor | Operational overhead not justified for a demo project |

**System design impact:** ACR is in the same Azure region as AKS — image pulls stay within the Azure backbone network (faster, no egress cost). AKS uses a managed identity attached to the kubelet to pull images — no registry credentials stored in Kubernetes secrets. Geo-replication is available if multi-region is added later.

**Security impact:** ACR is set to private access. Public access is disabled. Only the AKS managed identity and the CI service principal have pull/push permissions respectively.

---

### GitOps Engine: ArgoCD

**What it is:** A Kubernetes-native GitOps controller that continuously syncs a Git repository to a Kubernetes cluster.

**Why chosen over alternatives:**
| Alternative | Reason not chosen |
|-------------|-------------------|
| Flux v2 | ArgoCD has a richer UI for visibility into sync state — better for demos and learning |
| Spinnaker | Heavy, complex to operate, overkill for a microservices demo |
| Jenkins X | Opinionated pipeline model that would conflict with our separate CI design |
| Manual kubectl apply in CI | Push-based — requires cluster credentials in CI, larger blast radius on CI compromise |

**System design impact:** ArgoCD runs inside the cluster in its own namespace and pulls from Git — CI pipelines never touch the cluster directly. This is the key security boundary: a compromised CI system can only push to Git (which has its own PR review process), not directly to production. ArgoCD's sync status and health checks provide a live view of what is actually running versus what Git declares.

**Security impact:** ArgoCD uses a dedicated Git read-only deploy key with no write access. ArgoCD's own admin password is stored in Azure Key Vault. The ArgoCD UI is accessible only via port-forward or an internal load balancer — not exposed publicly.

---

### Manifest Templating: Kustomize

**What it is:** Kubernetes-native configuration management that layers environment-specific patches over a common base — no templating language required.

**Why chosen over alternatives:**
| Alternative | Reason not chosen |
|-------------|-------------------|
| Helm | Adds a templating layer and chart packaging model; useful for distributing third-party software, more overhead for first-party app config |
| Raw manifests per environment | Duplication — a change to a Deployment spec must be made in dev and prod separately |
| Jsonnet | Powerful but adds a programming language dependency for config |

**System design impact:** Base manifests define the structure (Deployment, Service, HPA). Overlays define environment-specific values (replica count, resource limits, image tag, namespace). Promoting a change from dev to prod is a copy of the patch — not a re-write. ArgoCD has native Kustomize support — no plugin needed.

---

### CI/CD: GitHub Actions + Azure DevOps Pipelines

**What they are:** Two separate CI/CD systems running complementary pipelines.

**Why both:**

| Pipeline | Tool | Reason |
|----------|------|--------|
| Application build + image push | GitHub Actions | Lives closest to the source code (GitHub repo); fast, native OIDC to ACR |
| Infrastructure provisioning | Azure DevOps Pipelines | Native Azure integration, approval gates on `terraform apply`, audit trail in Azure |

**System design impact:** The application pipeline does not touch infrastructure. The infrastructure pipeline does not build images. This separation means a Terraform change does not trigger a new image build, and a code change does not re-run infrastructure provisioning. Each pipeline is independently auditable.

**Security impact:** Both pipelines use OIDC (Workload Identity Federation) where possible — no long-lived secrets stored in CI. GitHub Actions uses Azure OIDC to authenticate to ACR. Azure DevOps uses a Managed Service Connection. The `terraform apply` step requires a manual approval gate in Azure DevOps before executing.

---

### Secrets Management: Azure Key Vault

**What it is:** Azure's managed secrets store for storing and rotating sensitive values.

**Why chosen over alternatives:**
| Alternative | Reason not chosen |
|-------------|-------------------|
| Kubernetes Secrets (native) | Base64-encoded, not encrypted at rest by default in etcd, no audit trail |
| HashiCorp Vault | Self-managed, operational overhead; Azure Key Vault is sufficient for this scope |
| Environment variables in CI | Not auditable, hard to rotate, leak risk in logs |

**System design impact:** The AKS Secret Store CSI driver mounts Key Vault secrets as files or environment variables inside pods — no secrets are stored in Git or Kubernetes Secrets objects. Rotation happens in Key Vault; pods pick up the new value on next sync without a re-deploy. Access is controlled by managed identity — pods get only the secrets their identity is permitted to read.

---

## Security Design Summary

| Layer | Control |
|-------|---------|
| Azure resources | Terraform-managed RBAC; no manual portal changes |
| Network | Private AKS API server; Calico network policies; ACR private endpoint |
| Container images | Immutable tags (Git SHA); ACR private; vulnerability scanning enabled |
| Kubernetes | RBAC enabled; Azure AD integration; namespace isolation |
| Secrets | Azure Key Vault + CSI driver; no secrets in Git or Kubernetes Secrets |
| CI credentials | OIDC / Workload Identity — no long-lived secrets in CI |
| GitOps | ArgoCD uses read-only deploy key; CI never touches cluster directly |
| Terraform state | Private Blob Storage; state locking; soft delete enabled |

---

## Cost Considerations

| Resource | Estimated Monthly Cost (East US) |
|----------|----------------------------------|
| AKS cluster (control plane) | Free (managed) |
| System node pool (1x Standard_D2s_v3) | ~$70 |
| User node pool (2x Standard_D4s_v3) | ~$280 |
| ACR (Basic tier) | ~$5 |
| Azure Blob Storage (state) | < $1 |
| Key Vault | < $5 |
| **Total (dev, single region)** | **~$360/month** |

> Costs can be reduced significantly by using Spot instances for the user node pool (~60-80% discount) and scaling node pools to zero outside working hours.

---

## Trade-offs and Decisions

| Decision | Trade-off accepted |
|----------|--------------------|
| ArgoCD over Flux | Richer UI and more demo-friendly; Flux has lower resource footprint |
| Kustomize over Helm | Less flexibility for complex templating; simpler for first-party app config |
| Two CI systems (GH Actions + ADO) | More moving parts to learn; better reflects real enterprise separation of concerns |
| Private AKS API server | Requires VPN or jump box for direct `kubectl` access outside CI; increases security |
| AKS managed identity for ACR | No credentials to manage; less portable to non-Azure environments |
| OIDC over service principal secrets | Requires Azure AD app registration setup; eliminates long-lived credential risk |
