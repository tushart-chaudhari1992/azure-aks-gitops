# Workflow and Commands

This document walks through every stage of the project lifecycle — from bootstrapping Azure to day-to-day operations. Each section explains what is happening, why the step is needed, and the exact commands to run.

---

## Stage 0: Prerequisites

Before anything else, verify the required tools are installed.

```bash
# Azure CLI — manages subscriptions, credentials, AKS kubeconfig
az --version             # need 2.55+

# Terraform — provisions all Azure infrastructure
terraform --version      # need 1.7+

# kubectl — interacts with the AKS cluster
kubectl version --client  # need 1.28+

# Kustomize — builds environment-specific manifests
kustomize version         # need 5.x

# ArgoCD CLI — syncs applications from the terminal
argocd version --client   # need 2.10+

# Node.js — required for MCP servers (GitHub, Kubernetes)
node --version            # need 18+
```

---

## Stage 1: Azure Account Setup

> **Why this stage:** All Terraform resources need an Azure subscription and a service principal with permission to create resources. This is a one-time bootstrap.

### 1.1 Log in to Azure

```bash
az login
# Opens browser — sign in with your Azure account
```

### 1.2 Set the active subscription

```bash
# List available subscriptions
az account list --output table

# Set the subscription you want to use
az account set --subscription "<subscription-id-or-name>"

# Confirm
az account show --output table
```

### 1.3 Create a service principal for Terraform and CI

```bash
# Creates a service principal with Contributor role on the subscription
# Save the output — you won't see the password again
az ad sp create-for-rbac \
  --name "boutique-terraform-sp" \
  --role Contributor \
  --scopes /subscriptions/<your-subscription-id> \
  --output json
```

Output will look like:
```json
{
  "appId": "...",        ← this is ARM_CLIENT_ID
  "displayName": "boutique-terraform-sp",
  "password": "...",     ← this is ARM_CLIENT_SECRET
  "tenant": "..."        ← this is ARM_TENANT_ID
}
```

Store these in a password manager — they are needed for every Terraform run and CI pipeline.

### 1.4 Bootstrap the Terraform remote state storage

> **Why:** Terraform state must exist in Azure Blob Storage before `terraform init` can run. This bootstrap is done manually once with the Azure CLI, not with Terraform (you can't use Terraform to create its own backend).

```bash
# Create the resource group for state storage
az group create \
  --name tfstate-rg \
  --location eastus

# Create the storage account (name must be globally unique)
az storage account create \
  --name boutiquetfstate \
  --resource-group tfstate-rg \
  --location eastus \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false   # no public access to state files

# Enable versioning — protects against accidental state corruption
az storage account blob-service-properties update \
  --account-name boutiquetfstate \
  --enable-versioning true

# Enable soft delete — 7 day recovery window
az storage account blob-service-properties update \
  --account-name boutiquetfstate \
  --delete-retention-days 7 \
  --enable-delete-retention true

# Create the container
az storage container create \
  --name tfstate \
  --account-name boutiquetfstate \
  --auth-mode login

# Verify
az storage container list \
  --account-name boutiquetfstate \
  --auth-mode login \
  --output table
```

---

## Stage 2: Infrastructure Provisioning (Terraform)

> **Why this stage:** All Azure resources (VNet, AKS, ACR, Key Vault, private endpoints) are declared in Terraform and must be provisioned before anything can run on Kubernetes.

Set the Terraform authentication environment variables:

```bash
export ARM_CLIENT_ID="<appId from step 1.3>"
export ARM_CLIENT_SECRET="<password from step 1.3>"
export ARM_TENANT_ID="<tenant from step 1.3>"
export ARM_SUBSCRIPTION_ID="<your subscription id>"
```

### 2.1 Dev environment

```bash
cd infrastructure/terraform/environments/dev

# Downloads the AzureRM provider and configures the remote backend
terraform init

# Shows exactly what will be created — review this before applying
terraform plan

# Apply — only run after reviewing the plan and getting approval per CLAUDE.md rules
terraform apply
```

Expected resources created:
- Resource group (`boutique-dev-rg`)
- Virtual network with 3 subnets (AKS, AppGW, private endpoints)
- AKS cluster (private, 1 system node + 2 user nodes)
- ACR with private endpoint and DNS zone
- Key Vault with private endpoint and DNS zone
- Log Analytics workspace

> **Cost impact:** ~$374/month for dev. See `docs/system-design.md` for the breakdown.

### 2.2 Prod environment

```bash
cd infrastructure/terraform/environments/prod

terraform init
terraform plan

# Prod requires explicit approval before apply — review the plan carefully
terraform apply
```

### 2.3 Get the AKS kubeconfig

> **Why:** After AKS is provisioned, you need a kubeconfig file so `kubectl` and the Kubernetes MCP server can talk to the cluster. Because the cluster is private, this must be run from inside the VNet or via Azure Cloud Shell.

```bash
az aks get-credentials \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --overwrite-existing

# Verify connection
kubectl get nodes
```

### 2.4 View Terraform state (inspection, no changes)

```bash
terraform show                          # full state
terraform state list                    # list all resources
terraform state show module.aks.azurerm_kubernetes_cluster.main   # specific resource
```

### 2.5 Destroy infrastructure (destructive — requires explicit approval)

```bash
# Dev only — never run against prod without a change request and approval
terraform destroy
```

---

## Stage 3: ArgoCD Bootstrap

> **Why this stage:** ArgoCD is the GitOps engine. It must be installed in the cluster before any application can be deployed via Git. This is a one-time setup per cluster.

### 3.1 Install ArgoCD

```bash
# Create the namespace
kubectl create namespace argocd

# Apply the patched ArgoCD install (runs in insecure mode — TLS terminated at LB)
kubectl apply -k gitops/argocd/install/

# Wait for all pods to be ready
kubectl rollout status deployment/argocd-server -n argocd
```

### 3.2 Get the initial admin password

```bash
argocd admin initial-password -n argocd
```

### 3.3 Log in to ArgoCD

```bash
# Port-forward the ArgoCD server (since it has no public endpoint)
kubectl port-forward svc/argocd-server -n argocd 8080:80 &

# Log in via CLI
argocd login localhost:8080 \
  --username admin \
  --password <initial-password> \
  --insecure

# Change the admin password immediately
argocd account update-password
```

### 3.4 Register the Git repository with ArgoCD

```bash
# HTTPS with a GitHub deploy token
argocd repo add https://github.com/<your-org>/<your-repo>.git \
  --username <github-username> \
  --password <github-personal-access-token>

# Or SSH with a deploy key
argocd repo add git@github.com:<your-org>/<your-repo>.git \
  --ssh-private-key-path ~/.ssh/argocd_deploy_key
```

### 3.5 Apply the Application manifests

```bash
# Deploy the dev application (auto-sync enabled)
kubectl apply -f gitops/argocd/apps/boutique-dev.yaml

# Deploy the prod application (manual sync — does not deploy automatically)
kubectl apply -f gitops/argocd/apps/boutique-prod.yaml

# Verify ArgoCD has picked them up
argocd app list
```

---

## Stage 4: First Application Deployment

> **Why this stage:** The first deployment pushes the application images to ACR and updates the GitOps overlays so ArgoCD can pull and deploy them.

### 4.1 Update the overlay ACR name (one-time)

Get your ACR login server:
```bash
az acr show --name boutiquedevacr --query loginServer --output tsv
```

Replace `boutiqueprodacr.azurecr.io` in both overlays with your actual ACR login server:
- `kubernetes/overlays/dev/kustomization.yaml`
- `kubernetes/overlays/prod/kustomization.yaml`

### 4.2 Build and push images manually (first time)

```bash
az acr login --name boutiquedevacr

SERVICES=(frontend cartservice productcatalogservice currencyservice \
          paymentservice shippingservice emailservice checkoutservice \
          recommendationservice adservice)

IMAGE_TAG="sha-$(git rev-parse HEAD)"

for SERVICE in "${SERVICES[@]}"; do
  docker build -t boutiquedevacr.azurecr.io/${SERVICE}:${IMAGE_TAG} src/${SERVICE}/
  docker push boutiquedevacr.azurecr.io/${SERVICE}:${IMAGE_TAG}
done
```

### 4.3 Update image tags in the dev overlay

```bash
cd kubernetes/overlays/dev

for SERVICE in frontend cartservice productcatalogservice currencyservice \
               paymentservice shippingservice emailservice checkoutservice \
               recommendationservice adservice; do
  kustomize edit set image \
    gcr.io/google-samples/microservices-demo/${SERVICE}=boutiquedevacr.azurecr.io/${SERVICE}:${IMAGE_TAG}
done

git add kustomization.yaml
git commit -m "ci: initial image tags ${IMAGE_TAG}"
git push
```

ArgoCD detects the change in Git and deploys automatically to dev within ~3 minutes.

### 4.4 Watch the sync in ArgoCD

```bash
argocd app get boutique-dev
argocd app sync boutique-dev   # force immediate sync if needed
argocd app wait boutique-dev --health
```

---

## Stage 5: Day-to-Day Operations

### 5.1 Check application health

```bash
# All pods in dev
kubectl get pods -n boutique-dev

# ArgoCD sync status
argocd app list

# Detailed sync and health status
argocd app get boutique-dev
argocd app get boutique-prod
```

### 5.2 View pod logs

```bash
# Stream logs from a specific service
kubectl logs -n boutique-dev -l app=frontend --follow

# Last 100 lines from cartservice
kubectl logs -n boutique-dev -l app=cartservice --tail=100

# Previous container logs (useful after a crash)
kubectl logs -n boutique-dev -l app=cartservice --previous
```

### 5.3 Inspect a failing pod

```bash
# Events — first place to look when a pod won't start
kubectl describe pod -n boutique-dev -l app=cartservice

# Resource usage (requires metrics-server)
kubectl top pods -n boutique-dev
kubectl top nodes
```

### 5.4 Promote a build to prod

```bash
# Get the tag currently running in dev
kubectl get deployment frontend -n boutique-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Update the prod overlay with that tag
cd kubernetes/overlays/prod
IMAGE_TAG="sha-<commit-sha>"
for SERVICE in frontend cartservice productcatalogservice currencyservice \
               paymentservice shippingservice emailservice checkoutservice \
               recommendationservice adservice; do
  kustomize edit set image \
    gcr.io/google-samples/microservices-demo/${SERVICE}=boutiqueprodacr.azurecr.io/${SERVICE}:${IMAGE_TAG}
done
git add kustomization.yaml
git commit -m "chore: promote ${IMAGE_TAG} to prod"
git push

# Sync prod manually (prod never auto-syncs — requires human decision)
argocd app sync boutique-prod

# Watch the rollout
argocd app wait boutique-prod --health
```

### 5.5 Roll back a deployment

```bash
# List ArgoCD rollout history
argocd app history boutique-dev

# Roll back to a previous revision
argocd app rollback boutique-dev <revision-number>

# Or revert the Git commit and let ArgoCD sync
git revert HEAD
git push
```

### 5.6 Access the frontend

```bash
# Get the external IP of the LoadBalancer service
kubectl get svc frontend-external -n boutique-dev

# Or port-forward for local access without a public IP
kubectl port-forward svc/frontend -n boutique-dev 8080:80
# Then open http://localhost:8080
```

---

## Stage 6: CI/CD Pipeline Triggers

### GitHub Actions

Triggered automatically on push to `main`. To trigger manually:
```bash
gh workflow run build-push.yml --ref main
gh run watch    # stream the run output
```

### Azure DevOps

Triggered on changes to `infrastructure/terraform/**`. To trigger manually:
```bash
az pipelines run --name "infrastructure" --branch main
az pipelines runs show --id <run-id>
```

---

## Stage 7: Claude Code Skills in This Workflow

These built-in Claude Code skills map directly to stages in this workflow:

| When to use | Skill | Command |
|-------------|-------|---------|
| Before merging any change to `infrastructure/` or pipelines | Security review | `/security-review` |
| Before merging a PR that updates K8s manifests or GitOps overlays | PR review | `/review` |
| After editing Terraform modules or pipeline YAML | Code quality check | `/simplify` |
| After running several sessions — too many permission prompts | Reduce prompts | `/fewer-permission-prompts` |
| Set up weekly drift detection or cost reports | Schedule a recurring agent | `/schedule` |

### Example: security review before a Terraform PR

```
# In Claude Code, after making changes to infrastructure/terraform/modules/
/security-review

# Claude will check for:
# - Overly broad IAM roles
# - Resources with public access enabled
# - Missing encryption settings
# - Network policies too permissive
# - Secrets or credentials in code
```

### Example: schedule a weekly drift check

```
/schedule run `terraform plan` in both environments every Monday morning
         and report if any unexpected changes are detected
```

---

## Quick Reference

```bash
# ── Terraform ────────────────────────────────────────────────────
terraform init                              # initialise backend and providers
terraform plan                              # show what will change
terraform apply                             # apply (requires approval per CLAUDE.md)
terraform state list                        # list all managed resources
terraform output                            # show output values

# ── kubectl ──────────────────────────────────────────────────────
kubectl get pods -n boutique-dev            # list pods
kubectl describe pod <name> -n boutique-dev # events and config
kubectl logs -n boutique-dev -l app=<svc>   # logs by label
kubectl top pods -n boutique-dev            # resource usage
kubectl rollout restart deployment/<name> -n boutique-dev

# ── ArgoCD ───────────────────────────────────────────────────────
argocd app list                             # all applications
argocd app get boutique-dev                 # health and sync status
argocd app sync boutique-dev                # force sync
argocd app rollback boutique-dev <rev>      # roll back to revision
argocd app history boutique-dev             # deployment history

# ── Kustomize ────────────────────────────────────────────────────
kustomize build kubernetes/overlays/dev     # preview rendered manifests
kustomize build kubernetes/overlays/prod    # preview prod manifests
kustomize edit set image <image>=<new>      # update an image tag in kustomization.yaml

# ── ACR ──────────────────────────────────────────────────────────
az acr login --name <acr-name>              # authenticate docker to ACR
az acr repository list --name <acr-name>   # list repositories
az acr repository show-tags --name <acr-name> --repository frontend

# ── MCP servers ──────────────────────────────────────────────────
/mcp                                        # check which servers are connected
```
