# Implementation Guide — Azure AKS GitOps Playbook

End-to-end runbook for deploying the Boutique demo stack on AKS with ArgoCD and GitHub Actions.  
Work through each phase in order. Phases 1–3 are already complete.

---

## Reference Values (already provisioned)

| Item | Value |
|------|-------|
| Azure Subscription ID | `3a2f7662-4ee2-4762-ab05-988439cdb9c4` |
| Azure Tenant ID | `90133fd7-1625-4ecb-90b2-6475f5df6b26` |
| GitHub Actions App (Client) ID | `565da2b4-54d4-423c-893d-bcc454a09383` |
| GitHub Actions SP Object ID | `5ccb4527-302c-4944-8bdb-f96b16f2cb6d` |
| GitHub repo | `tushart-chaudhari1992/azure-aks-gitops` |
| Region | `eastus` |
| Terraform state RG | `tfstate-rg` |
| Terraform state storage account | `tfstate3a2f7662` |
| Terraform state container | `tfstate` |
| Dev resource group | `boutique-dev-rg` *(created by Terraform)* |
| Dev AKS cluster | `boutique-dev-aks` *(created by Terraform)* |
| Dev ACR name | `boutiquedevacr` *(created by Terraform)* |
| Dev ACR login server | `boutiquedevacr.azurecr.io` *(created by Terraform)* |

---

## Phase 0 — Prerequisites & Account Details

### Required tools

| Tool | Install | Verify |
|------|---------|--------|
| Azure CLI | https://learn.microsoft.com/en-us/cli/azure/install-azure-cli | `az version` |
| Terraform ≥ 1.7 | https://developer.hashicorp.com/terraform/install | `terraform version` |
| kubectl | `az aks install-cli` | `kubectl version --client` |
| kustomize | `choco install kustomize` or https://kubectl.kustomize.io | `kustomize version` |
| Git | https://git-scm.com/downloads | `git --version` |

### Log in and gather required values

Run these first — you need the output before any other phase:

```bash
# Log in to Azure
az login

# Get subscription ID and tenant ID
az account show --query "{subscriptionId:id, tenantId:tenantId, name:name}" -o json

# If you have multiple subscriptions, set the right one
az account set --subscription "<subscription-id>"

# Get your current public IP (used to lock down AKS API server access)
curl ifconfig.me
# On Windows PowerShell:
# (Invoke-WebRequest ifconfig.me).Content

# Verify you are in the right subscription
az account show --query "{active_subscription:name, id:id}" -o table
```

### What each value is used for

| Value | Used for |
|-------|----------|
| `subscriptionId` | All resource scopes, role assignments, Terraform provider |
| `tenantId` | Service principal creation, OIDC federated credentials, Azure AD auth |
| Your public IP | `api_server_authorized_ip_ranges` in `terraform.tfvars` — locks down who can call `kubectl` |

---

## Phase 1 — Terraform State Storage ✅ DONE

```bash
az group create --name tfstate-rg --location eastus

az storage account create \
  --name tfstate3a2f7662 \
  --resource-group tfstate-rg \
  --location eastus \
  --sku Standard_LRS \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

az storage container create \
  --name tfstate \
  --account-name tfstate3a2f7662
```

---

## Phase 2 — GitHub Actions Service Principal (OIDC) ✅ DONE

OIDC means no stored client secrets — GitHub Actions proves its identity via a signed JWT.

```bash
APP_ID=$(az ad app create --display-name "boutique-github-actions" --query appId -o tsv)
SP_OBJ_ID=$(az ad sp create --id $APP_ID --query id -o tsv)

az role assignment create \
  --assignee $APP_ID \
  --role Contributor \
  --scope /subscriptions/3a2f7662-4ee2-4762-ab05-988439cdb9c4

# Federated credential — main branch pushes
az ad app federated-credential create --id $APP_ID --parameters \
  '{"name":"github-main","issuer":"https://token.actions.githubusercontent.com","subject":"repo:tushart-chaudhari1992/azure-aks-gitops:ref:refs/heads/main","audiences":["api://AzureADTokenExchange"]}'

# Federated credential — pull requests
az ad app federated-credential create --id $APP_ID --parameters \
  '{"name":"github-pr","issuer":"https://token.actions.githubusercontent.com","subject":"repo:tushart-chaudhari1992/azure-aks-gitops:pull_request","audiences":["api://AzureADTokenExchange"]}'
```

**Results:** App Client ID = `565da2b4-54d4-423c-893d-bcc454a09383`  
**Security note:** Contributor is scoped to the subscription for initial provisioning. After infrastructure stabilises, narrow to specific resource groups.

---

## Phase 3 — Repo Configuration ✅ DONE

Files updated with real values:

| File | Change |
|------|--------|
| `gitops/argocd/apps/boutique-dev.yaml` | GitHub repo URL filled in |
| `gitops/argocd/apps/boutique-prod.yaml` | GitHub repo URL filled in |
| `infrastructure/terraform/environments/dev/main.tf` | Terraform state storage account name |
| `infrastructure/terraform/environments/prod/main.tf` | Terraform state storage account name |
| `infrastructure/terraform/environments/dev/terraform.tfvars` | SP Object ID filled in |

---

## Phase 4 — GitHub Actions Secrets and Variables

Go to: **GitHub → repo → Settings → Secrets and variables → Actions**

### Secrets (encrypted, never shown in logs)

| Name | Value |
|------|-------|
| `AZURE_CLIENT_ID` | `565da2b4-54d4-423c-893d-bcc454a09383` |
| `AZURE_TENANT_ID` | `90133fd7-1625-4ecb-90b2-6475f5df6b26` |
| `AZURE_SUBSCRIPTION_ID` | `3a2f7662-4ee2-4762-ab05-988439cdb9c4` |

### Variables (non-secret, referenced as `vars.` in workflows)

Set these **after Terraform apply** in Phase 5:

| Name | Value |
|------|-------|
| `ACR_NAME` | `boutiquedevacr` |
| `ACR_LOGIN_SERVER` | `boutiquedevacr.azurecr.io` |

---

## Phase 5 — Terraform: Dev Environment

### ACR public access for GitHub Actions ✅ RESOLVED

Dev ACR has `public_network_access_enabled = true` so GitHub-hosted runners (public internet) can push images. The private endpoint still exists and is the only path pods use inside the cluster. Prod ACR keeps `public_network_access_enabled = false` (default) — prod CI must use a self-hosted runner inside the VNet.

### Cost estimate (dev environment, East US, monthly)

| Resource | SKU | Est. cost |
|----------|-----|-----------|
| AKS system node | Standard_D2s_v3 × 1 | ~$70 |
| AKS user nodes | Standard_D4s_v3 × 2 | ~$280 |
| ACR | Basic | ~$5 |
| Key Vault | Standard + 10K ops | ~$5 |
| Private endpoints × 2 | $0.01/hr each | ~$15 |
| Log Analytics | PerGB2018, 30-day retention | ~$5 |
| Load Balancer | Standard | ~$20 |
| **Total** | | **~$400/mo** |

**Shut down when not in use:** `terraform destroy` (confirm first — all data is lost).

### Commands

```bash
cd infrastructure/terraform/environments/dev

# Authenticate Terraform to Azure
az login
az account set --subscription 3a2f7662-4ee2-4762-ab05-988439cdb9c4

# Init — downloads providers and connects to remote state
terraform init

# Plan — review everything before any resource is created
terraform plan

# Apply — only after reviewing the plan output
# REQUIRES EXPLICIT APPROVAL before running
terraform apply
```

### Expected Terraform outputs (after apply)

```bash
terraform output
# aks_cluster_name         = "boutique-dev-aks"
# acr_login_server         = "boutiquedevacr.azurecr.io"
# key_vault_uri            = "https://boutique-dev-kv.vault.azure.net/"
# resource_group_name      = "boutique-dev-rg"
```

---

## Phase 6 — Post-Apply: Cluster Access

### ⚠️ Private cluster note

`private_cluster_enabled = true` means the AKS API server has no public endpoint. `kubectl` commands fail from outside the VNet. For dev, use `az aks command invoke` to run commands through the Azure API without VNet access.

```bash
# Get credentials (merges into ~/.kube/config but kubectl will timeout outside VNet)
az aks get-credentials \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks

# Use this instead of direct kubectl for dev:
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl get nodes"

# Alias shortcut (add to ~/.bashrc):
alias kaks='az aks command invoke --resource-group boutique-dev-rg --name boutique-dev-aks --command'
kaks "kubectl get pods -A"
```

For production or persistent access: deploy a jump box VM in the VNet and SSH-tunnel through it.

---

## Phase 7 — ArgoCD Bootstrap

Run all `kubectl` commands via `az aks command invoke` (see Phase 6).

### Install ArgoCD

```bash
# Create namespace and install (uses the kustomization in gitops/argocd/install/)
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl create namespace argocd" 

az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl apply -k https://github.com/tushart-chaudhari1992/azure-aks-gitops/gitops/argocd/install"

# Wait for all pods to be Running
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl rollout status deployment/argocd-server -n argocd"
```

### Get ArgoCD admin password

```bash
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
```

### Apply ArgoCD Application manifests

```bash
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl apply -f https://raw.githubusercontent.com/tushart-chaudhari1992/azure-aks-gitops/main/gitops/argocd/apps/boutique-dev.yaml"
```

ArgoCD will immediately start syncing `kubernetes/overlays/dev` from Git.

### Access the ArgoCD UI

Use a local port-forward via a jump box, or temporarily expose via a LoadBalancer (dev only):

```bash
# Dev shortcut — exposes ArgoCD UI publicly (NOT for production)
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl patch svc argocd-server -n argocd -p '{\"spec\":{\"type\":\"LoadBalancer\"}}'"

# Get the external IP (takes ~60s to assign)
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl get svc argocd-server -n argocd"
# Open https://<EXTERNAL-IP> in browser
# Login: admin / <password from above>
```

---

## Phase 7b — Terraform CI Pipeline (GitHub Actions)

File: `.github/workflows/terraform-dev.yml`

### Pipeline stages

```
security ──┐
           ├──► plan ──► apply (manual approval)
validate ──┘
```

| Stage | Tool | Blocks pipeline? | When |
|-------|------|-----------------|------|
| Security scan | Checkov | Yes — HIGH findings | PR + push |
| Security scan | tfsec | No — informational | PR + push |
| Validate | terraform fmt, validate, TFLint | Yes | PR + push |
| Plan | terraform plan | Yes — on error | PR + push |
| Plan comment | GitHub script | No | PR only |
| Apply | terraform apply | Requires approval | push to main only |

### One-time GitHub setup required

**1. Create the `dev` Environment with approval gate**

GitHub → repo → **Settings → Environments → New environment** → name it `dev`
- Add yourself as a required reviewer
- This is what blocks the apply job until you manually approve

**2. Secrets and variables** (already documented in Phase 4):
- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` must be set

### How it works on a PR

1. Checkov scans all Terraform in `infrastructure/terraform/` — fails on HIGH findings
2. tfsec runs and uploads results to the Security tab (informational)
3. `terraform fmt -check` and `terraform validate` run against the changed code
4. TFLint checks for type errors and deprecated syntax
5. `terraform plan` runs and posts the output as a collapsible comment on the PR

### How it works on merge to main

1. All of the above pass first
2. Apply job waits for a human to approve in GitHub → Actions → the run → Review deployments
3. Once approved, applies the exact plan file that was reviewed on the PR

### Checkov skip rationale

| Skipped check | Reason |
|---------------|--------|
| `CKV_AZURE_166` | ACR public access intentionally enabled for dev so GitHub-hosted runners can push images. Prod workflow will not skip this. |

### Trigger the first run

```bash
git add .github/workflows/terraform-dev.yml infrastructure/terraform/.tflint.hcl
git commit -m "ci: add Terraform pipeline with security scanning"
git push origin main
```

Watch it at: `https://github.com/tushart-chaudhari1992/azure-aks-gitops/actions`

---

## Phase 7c — App Security Pipeline (build-push.yml)

### Pipeline flow

```
secret-scan ──┐
sast ──────────┼──► build-push ──► image-scan (×10 parallel) ──► update-tags
sca ───────────┘

                                                  ↓  (after ArgoCD syncs)
                                               dast.yml (separate workflow)
```

### Security stages explained

| Stage | Tool | What it catches | Blocks build? |
|-------|------|----------------|---------------|
| Secret scan | Gitleaks | Secrets committed to git history | Yes |
| SAST | Semgrep | Code vulnerabilities (SQLi, XSS, hardcoded creds) | Yes |
| SCA | Trivy `fs` | HIGH/CRITICAL CVEs in dependency manifests | Yes |
| Build & push | Docker + ACR | — | — |
| Image scan | Trivy `image` (×10) | CRITICAL CVEs in OS packages inside containers | Yes |
| Update tags | kustomize + git | — | — |
| DAST | OWASP ZAP | Runtime vulnerabilities in the running app | Optional |

### DAST workflow (`dast.yml`)

DAST needs a running application to test against. Two ways to trigger it:

**Automatic** — fires ~90s after build-push completes (ArgoCD sync window):
- Set `DEV_FRONTEND_URL` as a GitHub Actions variable (repo → Settings → Variables → Actions)
- Value: the external IP of the frontend LoadBalancer (get after ArgoCD deploys)

**Manual** — go to Actions → DAST → Run workflow → enter the frontend URL

The ZAP baseline scan is **passive only** — it observes traffic and does not send attack payloads. Safe to run against dev at any time.

### Optional: Semgrep Cloud dashboard

Add `SEMGREP_APP_TOKEN` as a GitHub secret for findings to appear in Semgrep Cloud.  
Without it, Semgrep still runs OSS rules and blocks on findings — it just won't be tracked centrally.

### New GitHub variable needed for DAST (after Terraform apply)

| Name | Value |
|------|-------|
| `DEV_FRONTEND_URL` | `http://<frontend-loadbalancer-ip>` (get after Phase 9) |

---

## Phase 8 — First GitHub Actions Run (image build + push)

### Prerequisites
- Phase 4 GitHub secrets must be set
- ACR GitHub variables must be set (`ACR_NAME`, `ACR_LOGIN_SERVER`)
- The Online Boutique source code must be present at `src/<service>/Dockerfile`  
  Clone from: `https://github.com/GoogleCloudPlatform/microservices-demo`  
  Copy the `src/` directory into this repo.

### Trigger the pipeline

```bash
git add .
git commit -m "ci: trigger first image build"
git push origin main
```

Watch the run at: `https://github.com/tushart-chaudhari1992/azure-aks-gitops/actions`

### What happens

1. GitHub Actions builds each service Docker image
2. Images are tagged `sha-<commit-sha>` and pushed to `boutiquedevacr.azurecr.io`
3. Workflow runs `kustomize edit set image` to update `kubernetes/overlays/dev/kustomization.yaml`
4. Workflow commits and pushes the tag update back to `main`
5. ArgoCD detects the Git change and syncs the new image tags to the cluster

---

## Phase 9 — Verify

```bash
# All boutique pods should be Running
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl get pods -n boutique-dev"

# Check ArgoCD sync status
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl get applications -n argocd"

# Access the frontend (dev only — exposes publicly)
az aks command invoke \
  --resource-group boutique-dev-rg \
  --name boutique-dev-aks \
  --command "kubectl get svc frontend -n boutique-dev"
```

---

## Phase 10 — Prod Environment (after dev is stable)

1. Create `infrastructure/terraform/environments/prod/terraform.tfvars` with:
   ```hcl
   prefix                         = "boutique-prod"
   location                       = "eastus"
   ci_service_principal_object_id = "5ccb4527-302c-4944-8bdb-f96b16f2cb6d"
   api_server_authorized_ip_ranges = ["<jump-box-ip>/32"]
   ```
2. Run `terraform plan` in `environments/prod/` and review (3 nodes, Standard ACR — higher cost)
3. Apply ArgoCD `boutique-prod.yaml` — prod has **no** automated sync; a human must click Sync in ArgoCD UI after reviewing the diff

---

## Key Security Decisions

| Decision | Why |
|----------|-----|
| OIDC federated credentials | No long-lived client secrets stored in GitHub |
| Private AKS API server | API server not reachable from the internet |
| ACR private endpoint | Image registry not reachable from the internet |
| Key Vault private endpoint | Secrets store not reachable from the internet |
| Managed identity for AKS → ACR | AcrPull granted to kubelet identity; no credential rotation needed |
| Immutable image tags (`sha-<sha>`) | Prevents silent overwrite of deployed images |
| Dev: auto-sync, Prod: manual sync | Humans gate every production rollout |
| NetworkPolicy (Calico) | Pod-to-pod traffic restricted to declared paths only |

---

## Fixes Log — HCL Syntax Errors Found During `terraform init`

Documented here for reference: what was wrong, why, and what was changed.

### Fix 1 — Single-line variable blocks with two attributes

**Files affected:**
- `modules/acr/variables.tf`
- `modules/aks/variables.tf`
- `modules/keyvault/variables.tf`
- `modules/networking/variables.tf`

**Error:**
```
Error: Invalid single-argument block definition
  on ../../modules/acr/variables.tf line 4, in variable "sku":
  4: variable "sku" { type = string default = "Basic" }
A single-line block definition must end with a closing brace immediately
after its single argument definition.
```

**Root cause:** HCL only allows a single-line block (`{ ... }`) to contain **one** attribute. Variables with both `type` and `default` need to be written in multi-line format.

**Before (invalid):**
```hcl
variable "sku" { type = string default = "Basic" }
variable "tags" { type = map(string) default = {} }
variable "kubernetes_version" { type = string default = "1.29" }
variable "user_node_vm_size" { type = string default = "Standard_D4s_v3" }
variable "user_node_count" { type = number default = 2 }
variable "workload_identity_object_ids" { type = list(string) default = [] }
```

**After (valid):**
```hcl
variable "sku" {
  type    = string
  default = "Basic"
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

All affected variables expanded to multi-line format across all four module files.

---

### Fix 2 — Single-line provider block with two attributes

**Files affected:**
- `environments/dev/main.tf`
- `environments/prod/main.tf`

**Error:**
```
Error: Missing attribute separator
  on main.tf line 4, in terraform:
  4:     azurerm = { source = "hashicorp/azurerm" version = "~> 3.100" }
Expected a newline or comma to mark the beginning of the next attribute.
```

**Root cause:** Same rule — `source` and `version` are two attributes inside a single-line map. HCL requires a newline or comma separator.

**Before (invalid):**
```hcl
required_providers {
  azurerm = { source = "hashicorp/azurerm" version = "~> 3.100" }
}
```

**After (valid):**
```hcl
required_providers {
  azurerm = {
    source  = "hashicorp/azurerm"
    version = "~> 3.100"
  }
}
```

---

### Fix 3 — Azure CLI not in bash PATH

**Error:**
```
unable to build authorizer for Resource Manager API: could not configure AzureCli Authorizer:
exec: "az": executable file not found in %PATH%
```

**Root cause:** `terraform init` tries to authenticate using Azure CLI. On Windows, `az` is installed as a Windows application and its path (`C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin`) is in the Windows PATH but not visible in Git Bash / the Claude Code shell.

**Fix:** Run `terraform` commands in **PowerShell** or **Windows Terminal (cmd/PowerShell)** where Azure CLI is on the PATH — not in the Git Bash shell.

```powershell
# Run these in PowerShell, not Git Bash
cd D:\DevSecOps-Journey\azure-devops-ai-playbook\azure-aks-gitops\infrastructure\terraform\environments\dev
az login
terraform init
terraform plan
```

---

## Teardown (when done)

```bash
# Dev — destroys all resources in boutique-dev-rg (irreversible)
cd infrastructure/terraform/environments/dev
terraform destroy

# State storage — destroy last, manually
az group delete --name tfstate-rg --yes
```
