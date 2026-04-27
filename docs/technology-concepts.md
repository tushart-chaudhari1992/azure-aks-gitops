# Technology Concepts — Azure AKS GitOps Playbook

A concept-by-concept explanation of every technology used in this project,
with small examples drawn from the actual codebase.

---

## Table of Contents

1. [Docker & Container Images](#1-docker--container-images)
2. [Kubernetes](#2-kubernetes)
3. [Kustomize](#3-kustomize)
4. [ArgoCD](#4-argocd)
5. [Terraform](#5-terraform)
6. [Azure Kubernetes Service (AKS)](#6-azure-kubernetes-service-aks)
7. [Azure Container Registry (ACR)](#7-azure-container-registry-acr)
8. [Azure Key Vault](#8-azure-key-vault)
9. [GitHub Actions](#9-github-actions)
10. [Azure DevOps Pipelines](#10-azure-devops-pipelines)
11. [GitOps](#11-gitops)

---

## 1. Docker & Container Images

### What is a Container?

A container is a running process that is isolated from the host and from other containers.
It shares the host OS kernel but has its own filesystem, network, and process space.
Think of it as a lightweight virtual machine — but instead of virtualizing hardware, it
virtualizes the operating system.

### Image

An image is the blueprint for a container. It is a read-only, layered filesystem built from
a `Dockerfile`. When you run an image, you get a container.

```dockerfile
# Each instruction creates a new layer — layers are cached and reused
FROM node:20-alpine           # base layer: OS + runtime
WORKDIR /app
COPY package.json .           # layer: dependency list
RUN npm install               # layer: installed packages
COPY . .                      # layer: application code
EXPOSE 8080
CMD ["node", "server.js"]     # what runs when the container starts
```

### Tag

A tag is a version label attached to an image. In this project, every image is tagged with
the Git commit SHA to make deployments exactly reproducible and traceable:

```
boutiqueprodacr.azurecr.io/frontend:sha-a3f2c91
```

Using `latest` is an anti-pattern in production because it is mutable — two deploys with
`latest` may run different code.

### Registry

A registry stores and serves images. Docker Hub is the public default.
This project uses Azure Container Registry (ACR) as a private registry within the Azure VNet.

```bash
# Build and push with a SHA tag (from the CI pipeline)
IMAGE_TAG="sha-$(git rev-parse --short HEAD)"
docker build -t boutiqueprodacr.azurecr.io/frontend:$IMAGE_TAG ./src/frontend
docker push boutiqueprodacr.azurecr.io/frontend:$IMAGE_TAG
```

---

## 2. Kubernetes

Kubernetes (K8s) is a container orchestration platform. It manages how containers run across
a cluster of machines — scheduling, scaling, healing, networking, and configuration.

### Pod

The smallest deployable unit. A Pod wraps one or more containers that share a network
namespace (same IP, same ports) and optionally storage volumes. Pods are ephemeral —
they can be killed and replaced at any time.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: frontend
spec:
  containers:
    - name: server
      image: boutiqueprodacr.azurecr.io/frontend:sha-a3f2c91
      ports:
        - containerPort: 8080
```

You almost never create Pods directly — you let a Deployment manage them.

### ReplicaSet

A ReplicaSet ensures that a specified number of identical Pod replicas are running at all
times. If a Pod crashes, the ReplicaSet starts a new one. If you scale up, it creates more.

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: frontend
spec:
  replicas: 3          # always keep 3 copies running
  selector:
    matchLabels:
      app: frontend
  template:            # this is the Pod template
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: server
          image: boutiqueprodacr.azurecr.io/frontend:sha-a3f2c91
```

You almost never create ReplicaSets directly — Deployments manage them.

### Deployment

A Deployment is an abstraction over ReplicaSets. It adds **rolling updates** and
**rollbacks** on top of replica management. When you change the image tag, the Deployment
creates a new ReplicaSet with the new version, gradually shifts traffic to it, and
terminates the old one — with zero downtime.

```
Deployment → manages → ReplicaSet → manages → Pods → wraps → Containers
```

In this project every service is a Deployment:

```yaml
# kubernetes/base/frontend.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  selector:
    matchLabels:
      app: frontend
  template:
    spec:
      containers:
        - name: server
          image: gcr.io/google-samples/microservices-demo/frontend:v0.10.1
          resources:
            requests:
              cpu: 100m      # minimum CPU the scheduler reserves for this pod
              memory: 64Mi
            limits:
              cpu: 200m      # maximum CPU the container can use before being throttled
              memory: 128Mi
```

### Service

A Service gives a stable network identity to a set of Pods. Pods have dynamic IPs that change
every restart; a Service provides a single DNS name and IP that stays constant.

```
              ┌──────────────────┐
              │  Service         │    stable DNS: frontend.boutique.svc.cluster.local
              │  ClusterIP       │    stable port: 80
              └────────┬─────────┘
                       │ load-balances across
          ┌────────────┼────────────┐
          ▼            ▼            ▼
       Pod 1         Pod 2        Pod 3
```

Three Service types used in this project:

| Type | Where used | What it does |
|------|-----------|-------------|
| `ClusterIP` | All backend services | Internal-only access, only reachable within the cluster |
| `LoadBalancer` | `frontend-external` | Provisions an Azure Load Balancer with a public IP |

```yaml
# Internal service — only reachable by other pods in the cluster
apiVersion: v1
kind: Service
metadata:
  name: cartservice
spec:
  type: ClusterIP
  selector:
    app: cartservice    # routes to pods with this label
  ports:
    - port: 7070        # port you call the service on
      targetPort: 7070  # port on the pod
```

### Namespace

A Namespace is a logical partition inside a cluster. Resources in different Namespaces
are isolated from each other (by default). This project uses:

| Namespace | Purpose |
|-----------|---------|
| `boutique-dev` | Dev environment workloads |
| `boutique-prod` | Prod environment workloads |
| `argocd` | ArgoCD control plane |

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: boutique-dev
  labels:
    app.kubernetes.io/managed-by: argocd
```

### ServiceAccount

A ServiceAccount is the identity of a Pod within Kubernetes. It controls what Kubernetes
API operations the Pod is allowed to perform. Using the `default` ServiceAccount is an
anti-pattern — if compromised, all pods sharing it are at risk.

In this project each service has its own dedicated, locked-down ServiceAccount:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: boutique
automountServiceAccountToken: false   # do not inject K8s API token — frontend never calls the API
```

### SecurityContext

Controls the Linux security settings a container runs with. Applied at two levels:

**Pod level** — applies to all containers in the pod:
```yaml
spec:
  securityContext:
    runAsNonRoot: true    # pod will fail to start if image tries to run as root
    runAsUser: 1000       # run as UID 1000 instead of root (0)
    fsGroup: 2000         # mounted volumes are chowned to GID 2000 so non-root can write
```

**Container level** — fine-grained Linux controls:
```yaml
containers:
  - name: server
    securityContext:
      allowPrivilegeEscalation: false   # blocks sudo / setuid escalation
      readOnlyRootFilesystem: true      # container cannot write to its own filesystem
      capabilities:
        drop: ["ALL"]                   # removes all Linux capabilities (NET_RAW, SYS_ADMIN, etc.)
```

### Health Probes

Kubernetes uses probes to decide whether a Pod is ready to serve traffic and whether it
is still alive:

| Probe | Question | Action on failure |
|-------|---------|-------------------|
| `readinessProbe` | Is the pod ready to receive traffic? | Remove from Service endpoints |
| `livenessProbe` | Is the pod still functioning? | Kill and restart the pod |

```yaml
readinessProbe:
  httpGet:
    path: "/_healthz"
    port: 8080
  initialDelaySeconds: 10   # wait 10s after start before first check
  periodSeconds: 10         # check every 10s

livenessProbe:
  grpc:
    port: 7070              # gRPC health check (used by backend services)
  initialDelaySeconds: 15
  periodSeconds: 10
```

### NetworkPolicy

A NetworkPolicy is a firewall rule at the pod level. By default Kubernetes allows all
pod-to-pod communication. NetworkPolicies lock that down.

This project uses a **default-deny + explicit-allow** pattern:

```yaml
# Step 1: block everything
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}           # matches ALL pods
  policyTypes: [Ingress, Egress]

# Step 2: allow only what is needed
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-paymentservice
spec:
  podSelector:
    matchLabels:
      app: paymentservice
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: checkoutservice    # only checkoutservice may call paymentservice
    ports:
    - port: 50051
```

### HorizontalPodAutoscaler (HPA)

HPA automatically scales the number of Pod replicas based on a metric (CPU, memory, or custom).

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: frontend-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: frontend
  minReplicas: 3      # never go below 3
  maxReplicas: 10     # never exceed 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60   # scale up when average CPU > 60%
```

### PodDisruptionBudget (PDB)

A PDB prevents Kubernetes from taking down too many pods at once during voluntary
disruptions (node drains, cluster upgrades).

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
spec:
  minAvailable: 2           # always keep at least 2 pods running
  selector:
    matchLabels:
      app: frontend
```

Without a PDB, a node drain could evict all 3 replicas simultaneously, causing downtime.

### ResourceQuota & LimitRange

**ResourceQuota** caps the total resources a Namespace can consume:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: boutique-prod-quota
spec:
  hard:
    requests.cpu: "4"        # max 4 cores of CPU requested across all pods
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
    pods: "50"
```

**LimitRange** sets per-container defaults so pods without explicit requests still get
bounded resources:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: boutique-prod-limits
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: "100m"
        memory: "64Mi"
      default:
        cpu: "200m"
        memory: "128Mi"
```

---

## 3. Kustomize

Kustomize is a tool built into `kubectl` that lets you customize Kubernetes manifests
without templating or forking. It uses a **base + overlay** pattern.

### Base

The base contains the canonical, environment-agnostic manifests. You write them once.

```
kubernetes/base/
├── kustomization.yaml   ← lists all resources
├── frontend.yaml
├── cartservice.yaml
└── ...
```

```yaml
# kubernetes/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - serviceaccounts.yaml
  - networkpolicies.yaml
  - frontend.yaml
  - cartservice.yaml
```

### Overlay

An overlay references the base and applies environment-specific transformations —
without touching the base files.

```
kubernetes/overlays/
├── dev/
│   ├── kustomization.yaml   ← namespace: boutique-dev + dev image tags
│   └── resourcequota.yaml
└── prod/
    ├── kustomization.yaml   ← namespace: boutique-prod + prod image tags
    ├── patch-replicas.yaml  ← more replicas in prod
    ├── hpa.yaml
    ├── pdb.yaml
    └── resourcequota.yaml
```

### Image Override

The most important Kustomize feature in this project. CI updates the `newTag` field
after every build without touching the base manifests:

```yaml
# kubernetes/overlays/dev/kustomization.yaml
namespace: boutique-dev

images:
  - name: gcr.io/google-samples/microservices-demo/frontend   # match this image name in base
    newName: boutiqueprodacr.azurecr.io/frontend               # replace with ACR image
    newTag: sha-a3f2c91                                        # CI writes this tag here
```

### Strategic Merge Patch

Patches override specific fields in a base resource without rewriting the whole file:

```yaml
# kubernetes/overlays/prod/patch-replicas.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: boutique-prod
spec:
  replicas: 3    # override the base (which has no replicas field = defaults to 1)
```

### How Kustomize is applied

```bash
# preview what kustomize will generate (no apply)
kubectl kustomize kubernetes/overlays/dev

# apply the overlay to the cluster
kubectl apply -k kubernetes/overlays/dev
```

ArgoCD runs this automatically when it detects a Git change.

---

## 4. ArgoCD

ArgoCD is a GitOps controller that runs inside your Kubernetes cluster. It watches a Git
repository and continuously ensures the cluster matches what is declared in Git.

### The Pull Model

Traditional CI/CD **pushes** to the cluster: `kubectl apply` runs in a pipeline.
ArgoCD **pulls** from Git: the controller inside the cluster polls Git and applies changes.

```
CI Pipeline          Git Repo            ArgoCD (in cluster)
──────────           ────────            ───────────────────
build image    →     commit image tag    ←── polls every 3m
                     to kustomization.yaml    detects diff
                                              applies it
                                              reports sync status
```

Benefits of pull: CI never needs cluster credentials. The cluster only ever talks outbound.

### Application CRD

The core ArgoCD resource. It declares what to deploy, from where, and to where:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: boutique-dev
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/your-org/azure-aks-gitops
    targetRevision: main
    path: kubernetes/overlays/dev     # which directory to render
  destination:
    server: https://kubernetes.default.svc   # this cluster
    namespace: boutique-dev
  syncPolicy:
    automated:
      prune: true       # delete resources removed from Git
      selfHeal: true    # revert manual kubectl changes
    retry:
      limit: 3
      backoff:
        duration: 5s
        maxDuration: 3m
```

### Dev vs Prod Sync Strategy

| Setting | Dev | Prod |
|---------|-----|------|
| Sync | Automatic | Manual (human clicks Sync in UI) |
| `prune` | true | false — conservative, never auto-delete prod |
| `selfHeal` | true | false — allows emergency kubectl patches |
| Retry limit | 3 | 2 |

### ArgoCD Bootstrap (first-time only)

ArgoCD itself is installed via Kustomize before it can manage anything:

```bash
kubectl create namespace argocd
kubectl apply -k gitops/argocd/install/    # installs ArgoCD CRDs + controllers
kubectl apply -f gitops/argocd/apps/boutique-dev.yaml   # registers the first Application
```

After that, ArgoCD manages itself and all subsequent changes are made via Git.

---

## 5. Terraform

Terraform is an Infrastructure as Code (IaC) tool. You declare what Azure resources you
want in `.tf` files; Terraform figures out how to create, update, or delete them to match.

### Provider

The provider is the plugin that speaks to a cloud API. This project uses the AzureRM provider:

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  # credentials come from ARM_CLIENT_ID / ARM_CLIENT_SECRET env vars (set in pipeline)
}
```

### Resource

A resource is a single piece of infrastructure. Terraform creates, reads, updates, and
deletes resources to match your declaration:

```hcl
resource "azurerm_resource_group" "main" {
  name     = "boutique-prod-rg"
  location = "East US"
}
```

### Module

A module is a reusable group of resources. This project has four modules:

```
infrastructure/terraform/modules/
├── networking/   ← VNet, subnets, private DNS zones
├── aks/          ← AKS cluster, node pools, RBAC
├── acr/          ← Azure Container Registry
└── keyvault/     ← Key Vault, access policies
```

Using a module:
```hcl
# infrastructure/terraform/environments/prod/main.tf
module "aks" {
  source              = "../../modules/aks"
  resource_group_name = azurerm_resource_group.main.name
  cluster_name        = "boutique-prod-aks"
  node_count          = 2
  vm_size             = "Standard_D4s_v3"
  subnet_id           = module.networking.aks_subnet_id
}
```

### State

Terraform tracks what it has deployed in a **state file**. Without state, it cannot know
what already exists vs what needs to be created. This project stores state remotely in
Azure Blob Storage so the whole team shares the same view:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "boutique-tfstate-rg"
    storage_account_name = "boutiquetfstate"
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"
  }
}
```

State locking (via Blob leases) prevents two people from running `apply` simultaneously.

### Plan → Apply Workflow

Terraform never applies blindly. The workflow is always:

```bash
terraform init     # download providers and modules
terraform plan     # show what WILL change — read this carefully
terraform apply    # apply the changes (requires approval in this project)
```

The `plan` output in the pipeline is published as an artifact so a human can review before
applying — especially for prod.

### Variables and Outputs

Variables make modules reusable across environments:

```hcl
# modules/aks/variables.tf
variable "node_count" {
  type        = number
  description = "Number of nodes in the user node pool"
}

# modules/aks/outputs.tf
output "cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}
```

---

## 6. Azure Kubernetes Service (AKS)

AKS is Azure's managed Kubernetes service. Microsoft operates the control plane
(API server, etcd, scheduler) for free. You pay only for the worker nodes.

### Node Pools

A node pool is a group of VMs that run your pods. This project uses two pools:

| Pool | VM Size | Purpose |
|------|---------|---------|
| System pool | Standard_D2s_v3 | Runs kube-system pods (CoreDNS, metrics-server) |
| User pool | Standard_D4s_v3 | Runs boutique application pods |

Separating system and user pools means a misbehaving app cannot starve the system pods.

### Azure AD Integration (RBAC)

AKS integrates with Azure Active Directory. Instead of managing Kubernetes RBAC users
manually, you use Azure AD groups:

```hcl
resource "azurerm_kubernetes_cluster" "main" {
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids = [var.admin_group_id]
  }
}
```

This means `kubectl` access requires a valid Azure AD login — no static kubeconfig credentials.

### Managed Identity

Instead of service principal credentials (username + password), AKS uses Managed Identities.
Pods that need to access Azure resources (ACR, Key Vault) authenticate automatically via
their assigned managed identity — no secrets stored anywhere.

```hcl
resource "azurerm_kubernetes_cluster" "main" {
  identity {
    type = "SystemAssigned"   # Azure assigns and rotates the identity automatically
  }
  kubelet_identity {
    # this identity is used by nodes to pull images from ACR
  }
}
```

### Private Cluster

In this project, the AKS API server has no public endpoint. `kubectl` only works from
within the VNet (or via a VPN/bastion):

```hcl
resource "azurerm_kubernetes_cluster" "main" {
  private_cluster_enabled = true   # API server gets a private IP only
}
```

This means CI agents must be self-hosted inside the VNet — Azure DevOps self-hosted agents
are used for this reason.

---

## 7. Azure Container Registry (ACR)

ACR is a private Docker registry hosted in Azure. It stores your container images and
serves them to AKS during pod scheduling.

### Repository and Tag

```
boutiqueprodacr.azurecr.io     ← registry (ACR endpoint)
/frontend                       ← repository (one per service)
:sha-a3f2c91                    ← tag (immutable, tied to a Git commit)
```

### Private Endpoint

ACR is configured with no public access. Images are pulled over a private IP within the VNet:

```hcl
resource "azurerm_private_endpoint" "acr" {
  name                = "acr-private-endpoint"
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "acr-connection"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
  }
}
```

### AKS → ACR Integration

AKS nodes are granted `AcrPull` permission on ACR via Managed Identity — no Docker login
credentials are needed in any pod or pipeline:

```hcl
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
```

---

## 8. Azure Key Vault

Key Vault is Azure's managed secrets store. Secrets (database passwords, API keys,
connection strings) live in Key Vault instead of Kubernetes Secrets or Git.

### Secret

A Key Vault Secret is a named, versioned, encrypted value:

```bash
az keyvault secret set \
  --vault-name boutique-prod-kv \
  --name redis-password \
  --value "super-secret-value"
```

### CSI Driver (Secrets Store)

The Secrets Store CSI Driver bridges Key Vault and Kubernetes. It mounts Key Vault secrets
as files or environment variables inside pods — without ever storing them in Kubernetes:

```yaml
# A SecretProviderClass tells the CSI driver which Key Vault secrets to fetch
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: boutique-secrets
spec:
  provider: azure
  parameters:
    keyvaultName: boutique-prod-kv
    objects: |
      - objectName: redis-password
        objectType: secret
```

```yaml
# Pod mounts the secrets as files
volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: boutique-secrets
```

### Private Endpoint

Like ACR, Key Vault has no public access — only reachable within the VNet:

```hcl
resource "azurerm_private_endpoint" "keyvault" {
  private_service_connection {
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
  }
}
```

### Soft Delete

Key Vault retains deleted secrets for 90 days by default. This prevents accidental
permanent loss of production credentials:

```hcl
resource "azurerm_key_vault" "main" {
  soft_delete_retention_days = 90
  purge_protection_enabled   = true   # prevents immediate permanent deletion
}
```

---

## 9. GitHub Actions

GitHub Actions is a CI/CD system built into GitHub. Workflows are YAML files in
`.github/workflows/` that run automatically on Git events.

### Workflow Structure

```
Workflow (file)
└── Trigger (when to run)
└── Job (where to run — ubuntu-latest, self-hosted, etc.)
    └── Steps (what to do)
        └── Actions (reusable steps from the marketplace)
        └── Run commands (inline bash)
```

### Trigger

```yaml
on:
  push:
    branches: [main]
    paths: [src/**]      # only run when source code changes, not on docs edits
  pull_request:
    branches: [main]
```

### OIDC — No Long-Lived Secrets

The most important security concept in the GitHub Actions workflow. Instead of storing
Azure service principal credentials as GitHub Secrets (which can leak), the workflow
uses OpenID Connect (OIDC):

```yaml
permissions:
  id-token: write      # allows the job to request a short-lived OIDC token

steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ secrets.AZURE_CLIENT_ID }}
      tenant-id: ${{ secrets.AZURE_TENANT_ID }}
      subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      # No client-secret needed — GitHub generates a short-lived JWT token
      # Azure validates the token against the GitHub OIDC provider
```

How it works:
1. GitHub generates a JWT signed by GitHub's OIDC provider
2. The `azure/login` action exchanges this JWT for a short-lived Azure access token
3. The token expires when the job ends — nothing to rotate or leak

### Job — Build and Push

```yaml
jobs:
  build-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set image tag
        run: echo "IMAGE_TAG=sha-${{ github.sha }}" >> $GITHUB_ENV

      - name: Build and push all services
        run: |
          for SERVICE in frontend cartservice productcatalogservice; do
            docker build -t $ACR_LOGIN_SERVER/$SERVICE:$IMAGE_TAG ./src/$SERVICE
            docker push $ACR_LOGIN_SERVER/$SERVICE:$IMAGE_TAG
          done

      - name: Update dev overlay image tags
        run: |
          cd kubernetes/overlays/dev
          kustomize edit set image \
            gcr.io/google-samples/microservices-demo/frontend=$ACR_LOGIN_SERVER/frontend:$IMAGE_TAG

      - name: Commit and push updated tags
        run: |
          git config user.email "ci@github.com"
          git add kubernetes/overlays/dev/kustomization.yaml
          git commit -m "ci: update dev image tags to $IMAGE_TAG"
          git push
```

The last step writes the new image tag to Git, which triggers ArgoCD to deploy it.

---

## 10. Azure DevOps Pipelines

Azure DevOps Pipelines is Microsoft's CI/CD system. This project uses it alongside
GitHub Actions — GitHub Actions for application builds, Azure DevOps for infrastructure.

### Why Two CI Systems?

The project deliberately runs both to demonstrate that pipelines are interchangeable.
In practice you would choose one. Azure DevOps is used for Terraform because its
**Environments** feature provides a richer approval gate for production infrastructure.

### Pipeline Structure

```
Pipeline (YAML file in .azuredevops/pipelines/)
└── Stage (logical phase — Dev, Prod)
    └── Job (runs on an agent)
        └── Step (individual task or bash command)
```

### Self-Hosted Agent

Because AKS and ACR have no public endpoints, Azure DevOps must run its agent
inside the VNet — it cannot use Microsoft-hosted agents (which run on public internet):

```yaml
pool:
  name: self-hosted-agents   # your own VM inside the Azure VNet
```

The self-hosted agent has network access to the private AKS API server and private ACR endpoint.

### Variable Group

A Variable Group is a shared set of secrets configured in the Azure DevOps UI (not in
YAML files — never in Git):

```yaml
variables:
  - group: terraform-secrets   # contains ARM_CLIENT_ID, ARM_CLIENT_SECRET, etc.
```

### Environments with Approval Gates

An Environment in Azure DevOps wraps a deployment target. You configure human approvals
on the Environment in the UI — the pipeline pauses and sends a notification:

```yaml
jobs:
  - deployment: TerraformApply
    environment: production       # pauses here until a human approves in the Azure DevOps UI
    strategy:
      runOnce:
        deploy:
          steps:
            - script: terraform apply -auto-approve
```

### Two-Stage Terraform Pipeline

```
┌─────────────────────────────────────────┐
│ Stage: TerraformDev                     │
│   Job: Plan  → creates tfplan artifact  │
│   Job: Apply → manual approval → apply  │
└─────────────────────────────────────────┘
              depends on ↓
┌─────────────────────────────────────────┐
│ Stage: TerraformProd                    │
│   Job: Plan+Apply → Environment gate   │
└─────────────────────────────────────────┘
```

---

## 11. GitOps

GitOps is a practice, not a tool. It means **Git is the single source of truth** for
both application code and infrastructure configuration. Every desired state is declared
in Git; automated tooling (ArgoCD) reconciles the cluster to match.

### Core Principles

| Principle | What it means in this project |
|-----------|-------------------------------|
| **Declarative** | Kubernetes YAML describes desired state, not steps to get there |
| **Versioned** | Every change is a Git commit with a SHA, author, and message |
| **Pull-based** | ArgoCD pulls from Git — CI never touches the cluster directly |
| **Automated reconciliation** | ArgoCD detects drift and corrects it automatically (dev) |

### Immutable Image Tags

The tag `sha-a3f2c91` means "the exact code at commit a3f2c91." If you need to roll back,
you change the tag in Git and ArgoCD deploys the old image. You never rebuild to roll back.

```
Git history:
  a3f2c91  frontend:sha-a3f2c91  ← currently deployed
  b7e1d02  frontend:sha-b7e1d02  ← bad release
  c9f3a11  frontend:sha-c9f3a11  ← latest, broken

Rollback = git revert b7e1d02 → ArgoCD deploys sha-a3f2c91 again
```

### The Full Delivery Flow

```
Developer pushes code
        │
        ▼
GitHub Actions (CI)
  ├── docker build
  ├── docker push → ACR (sha-<commit>)
  ├── kustomize edit set image → updates overlays/dev/kustomization.yaml
  └── git commit + push

        │  (Git now has the new image tag)
        ▼
ArgoCD (in AKS, polls Git every 3 min)
  ├── detects kustomization.yaml changed
  ├── renders kustomize overlays/dev
  ├── compares rendered manifests to live cluster
  └── applies the diff → rolling update of pods

        │  (new pods start, old pods terminate)
        ▼
Cluster running sha-<commit> image
```

### Dev vs Prod Promotion

Dev is automatic; prod requires a deliberate human decision:

```
Auto-deployed to boutique-dev by ArgoCD
        │
        ▼
Team tests in dev environment
        │
        ▼
Human manually syncs boutique-prod in ArgoCD UI
        │
        ▼
ArgoCD deploys same image tag to boutique-prod
```

The same Git SHA and the same container image run in both environments.
The only difference is the Kustomize overlay (replicas, resource quotas, HPA, PDB).

---

## Concept Map — How Everything Connects

```
Developer
  │ git push
  ▼
GitHub / Azure DevOps
  ├── GitHub Actions builds Docker image → pushes to ACR → updates Git (image tag)
  └── Azure DevOps runs Terraform → provisions AKS, ACR, Key Vault in Azure

ArgoCD (running in AKS)
  │ polls Git
  ▼
Kustomize renders overlays (base + patches + image overrides)
  │
  ▼
Kubernetes resources created in AKS
  ├── Namespaces (boutique-dev, boutique-prod)
  ├── ServiceAccounts (one per service, no default SA)
  ├── NetworkPolicies (default-deny + explicit allow)
  ├── Deployments → ReplicaSets → Pods → Containers (images from ACR)
  ├── Services (ClusterIP for backends, LoadBalancer for frontend)
  ├── HPA (auto-scale frontend, checkout, cart, payment)
  ├── PDB (protect against drain downtime in prod)
  └── ResourceQuota + LimitRange (namespace guardrails)

Azure infrastructure (managed by Terraform)
  ├── AKS (managed Kubernetes, private API server)
  ├── ACR (private image registry, private endpoint)
  ├── Key Vault (secrets, private endpoint, CSI driver)
  └── VNet + subnets (network boundary for everything above)
```
