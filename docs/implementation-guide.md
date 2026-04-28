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

## Impact of Not Adding .gitignore, .dockerignore and .gitattributes

### .gitignore — what gets accidentally committed without it

| File/folder accidentally committed | Impact |
|------------------------------------|--------|
| `.terraform/` | 200–500 MB of provider binaries pushed to GitHub. Repo becomes unusable to clone. Repeated on every `terraform init`. |
| `*.tfstate` | State files contain **plaintext resource IDs, connection strings, and sometimes secrets** (Key Vault URIs, AKS kubeconfig). Anyone with repo read access can extract them. |
| `*.tfplan` | Plan files encode the full diff including sensitive values marked `(sensitive)` in CLI output. They are not encrypted. |
| `.env` / `*.key` / `*.pem` | Direct secret exposure. GitHub scans for some patterns and alerts, but the secret is already in history and must be rotated even after deletion. |
| `kubeconfig` | Grants full cluster access to anyone who obtains it. Private AKS clusters are then reachable via `az aks command invoke`. |
| `*.sarif` / scan reports | Leak vulnerability details about your own application — helps attackers target known weak points. |

**Key rule:** Once a secret is committed to git, it is in the history forever. Even `git rm` + force-push does not remove it from forks, local clones, or GitHub's caches. You must rotate the credential immediately.

---

### .dockerignore — what goes into the image without it

| Included without .dockerignore | Impact |
|-------------------------------|--------|
| `infrastructure/` + `*.tfvars` | Terraform state paths, SP Object IDs, and subscription IDs baked into the image layer. Extractable via `docker history` or `docker save`. |
| `.env` files | Secrets inside the image. Anyone who pulls the image from ACR (or a leaked registry) has the secrets. |
| `node_modules/` / `vendor/` | Development dependencies with test/dev packages included in the production image. Larger attack surface, larger image (often 3–10× bigger). |
| `test/` folders | Test code and fixtures, sometimes containing mock credentials or real-looking test data. |
| `.git/` | Full repository history inside the container — leaks every past commit, author, and branch name. |

**Practical effect:** Without .dockerignore, a 50 MB app image can become 800 MB+, pull times spike, and cold-start latency on the cluster increases significantly.

---

### .gitattributes — what breaks without it

| Scenario | Impact |
|----------|--------|
| Windows developer commits CRLF line endings | Linux CI runner (Ubuntu) receives files with `\r\n`. Shell scripts fail with `bad interpreter: No such file or directory`. YAML and HCL parsers may reject them. |
| Mixed line endings in the same file | Git diffs show entire files as changed even when only one line was edited — PR reviews become unreadable. |
| Terraform HCL files with CRLF | `terraform fmt` on Linux sees different line endings and re-formats every file on every run, creating spurious commits in CI. |
| GitHub Actions YAML with CRLF | The Actions runner may fail to parse the workflow correctly, producing confusing syntax errors unrelated to the actual YAML content. |

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

### Fix 4 — OIDC Federated Credential Subject Corrupted (shell line-wrap)

**Error (in GitHub Actions):**
```
AADSTS700213: No matching federated identity record found for presented assertion
subject 'repo:tushart-chaudhari1992/azure-aks-gitops:ref:refs/heads/main'
```

**Root cause:** When the federated credential creation commands were run, the shell line-wrapped the long username `tushart-chaudhari1992` mid-word, storing spaces inside the string. Azure stored:
```
repo:tushart  -chaudhari1992/azure-aks-gitops:ref:refs/heads/main   ← broken (spaces)
```
instead of:
```
repo:tushart-chaudhari1992/azure-aks-gitops:ref:refs/heads/main     ← correct
```
Azure's subject matching is exact — one space causes a total mismatch.

**How to diagnose:** Always verify credentials after creating them:
```bash
az ad app federated-credential list \
  --id <APP_ID> \
  --query "[].{name:name, subject:subject}" \
  --output json
```

**Fix:** Delete the broken credentials and recreate with the exact correct subject:
```bash
# List existing credential IDs
az ad app federated-credential list --id 565da2b4-54d4-423c-893d-bcc454a09383 --query "[].id" --output tsv

# Delete both broken credentials (replace IDs with your output above)
az ad app federated-credential delete --id 565da2b4-54d4-423c-893d-bcc454a09383 --federated-credential-id <ID-1>
az ad app federated-credential delete --id 565da2b4-54d4-423c-893d-bcc454a09383 --federated-credential-id <ID-2>

# Recreate with correct subjects
az ad app federated-credential create --id 565da2b4-54d4-423c-893d-bcc454a09383 --parameters \
  '{"name":"github-main","issuer":"https://token.actions.githubusercontent.com","subject":"repo:tushart-chaudhari1992/azure-aks-gitops:ref:refs/heads/main","audiences":["api://AzureADTokenExchange"]}'

az ad app federated-credential create --id 565da2b4-54d4-423c-893d-bcc454a09383 --parameters \
  '{"name":"github-pr","issuer":"https://token.actions.githubusercontent.com","subject":"repo:tushart-chaudhari1992/azure-aks-gitops:pull_request","audiences":["api://AzureADTokenExchange"]}'
```

**Prevention:** Always pass federated credential parameters as a single unbroken line or use a JSON file:
```bash
# Safer — use a temp file to avoid shell line-wrap issues
cat > /tmp/fed-cred.json <<EOF
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:tushart-chaudhari1992/azure-aks-gitops:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
az ad app federated-credential create --id 565da2b4-54d4-423c-893d-bcc454a09383 --parameters @/tmp/fed-cred.json
```

---

### Fix 5 — terraform fmt -check fails in CI (exit code 3)

**Error (in GitHub Actions validate job):**
```
Error: Terraform exited with code 3.
Error: Process completed with exit code 1.
```

**Root cause:** `terraform fmt -check` exits with a non-zero code when any `.tf` or `.tfvars` file is not canonically formatted. Exit code 3 on Windows (vs 1 on Linux) is how PowerShell and Git Bash report the same error differently — but the effect is identical: the pipeline fails.

The 5 files that were not formatted:
- `environments/dev/main.tf`
- `environments/dev/terraform.tfvars`
- `environments/prod/main.tf`
- `modules/aks/main.tf`
- `modules/networking/main.tf`

Common formatting issues caught by `terraform fmt`:
- Inline comment spacing (two spaces before `#`)
- Argument alignment (extra spaces to align `=` signs across attributes)
- Indentation (must be 2 spaces, not tabs)

**Fix:** Run `terraform fmt` locally before every commit to auto-fix all files:
```bash
# Fix all files recursively from the terraform root
terraform fmt -recursive infrastructure/terraform/

# Verify — no output and exit code 0 means all files are clean
terraform fmt -check -recursive infrastructure/terraform/
```

**Prevention:** Add this to your local git pre-commit hook or always run fmt before pushing:
```bash
# One-liner to add as a pre-commit hook
echo '#!/bin/sh\nterraform fmt -check -recursive infrastructure/terraform/ || { echo "Run: terraform fmt -recursive infrastructure/terraform/"; exit 1; }' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

---

### Fix 6 — azurerm provider falls back to Azure CLI auth in GitHub Actions (ARM_USE_OIDC missing)

**Error (in GitHub Actions validate job, after `azure/login@v2`):**
```
Error: Error building ARM Config: Authenticating using the Azure CLI is only supported
as a User (not a Service Principal).
```

**Root cause:** The azurerm Terraform provider has an authentication priority chain:
1. Managed Identity
2. OIDC (workload identity federation) — needs `ARM_USE_OIDC=true` explicitly set
3. Azure CLI — **this is what it falls back to**

When `azure/login@v2` runs in GitHub Actions, it logs in the runner as a **Service Principal** via the OIDC token (not an interactive user). Azure CLI then holds a SP session. When azurerm tries to use the CLI for auth it rejects the SP session — only interactive user sessions are supported via CLI.

The fix is to explicitly tell azurerm to use the OIDC path directly, bypassing the CLI entirely.

**Fix:** Add a step immediately after every `azure/login@v2` in the validate, plan, and apply jobs to export the four required ARM environment variables:

```yaml
- name: Set ARM credentials for Terraform OIDC
  run: |
    echo "ARM_USE_OIDC=true" >> $GITHUB_ENV
    echo "ARM_CLIENT_ID=${{ secrets.AZURE_CLIENT_ID }}" >> $GITHUB_ENV
    echo "ARM_TENANT_ID=${{ secrets.AZURE_TENANT_ID }}" >> $GITHUB_ENV
    echo "ARM_SUBSCRIPTION_ID=${{ secrets.AZURE_SUBSCRIPTION_ID }}" >> $GITHUB_ENV
```

**Why `$GITHUB_ENV` and not `env:` block?** The `env:` block at the job level can't reference `secrets` that are injected per-step. Writing to `$GITHUB_ENV` makes variables available to all subsequent steps in the same job.

**Files changed:**
- `.github/workflows/terraform-dev.yml` — added the step to validate, plan, and apply jobs

**How azurerm OIDC auth works:**
1. `azure/login@v2` exchanges the GitHub OIDC JWT for an Azure AD access token and stores it in the runner's environment.
2. With `ARM_USE_OIDC=true`, the azurerm provider calls `az account get-access-token` to retrieve the OIDC token from the login action's context — no CLI user session needed.
3. azurerm then authenticates directly to Azure Resource Manager with that token.

---

### Fix 7 — Checkov security scan failures (14 checks across ACR, AKS, networking)

**Error (in GitHub Actions security job):**
```
Check: CKV_AZURE_141: "Ensure AKS local admin account is disabled"   FAILED
Check: CKV_AZURE_171: "Ensure AKS cluster upgrade channel is chosen"  FAILED
Check: CKV_AZURE_116: "Ensure that AKS uses Azure Policies Add-on"    FAILED
Check: CKV_AZURE_168: "Ensure AKS nodes have minimum 50 pods"         FAILED
Check: CKV_AZURE_172: "Ensure autorotation of Secrets Store CSI"      FAILED
Check: CKV2_AZURE_31: "Ensure VNET subnet configured with NSG"        FAILED
Check: CKV_AZURE_233/237/165/163/164/117/227/170/226/139: ...         FAILED
Path does not exist: tfsec-results.sarif
```

---

#### Checks fixed in Terraform code

These are free controls that add real security value with no cost overhead.

| Check | Control added | File | Impact of NOT fixing |
|---|---|---|---|
| `CKV_AZURE_141` | `local_account_disabled = true` | `modules/aks/main.tf` | Any holder of the static kubeconfig has cluster-admin regardless of Azure AD policy. An exfiltrated kubeconfig becomes a permanent backdoor. |
| `CKV_AZURE_171` | `automatic_channel_upgrade = "stable"` | `modules/aks/main.tf` | Cluster falls behind on Kubernetes CVE patches. Each minor version left un-upgraded is a window for known exploits (e.g., container escapes, privilege escalation). |
| `CKV_AZURE_116` | `azure_policy_enabled = true` | `modules/aks/main.tf` | No guardrails on what pods can do — privileged containers, missing resource limits, host-path mounts all allowed by default. Azure Policy blocks these at admission time. |
| `CKV_AZURE_168` | `max_pods = 110` on both node pools | `modules/aks/main.tf` | Low pod density means you need more nodes for the same workload. Default of 30 on Azure CNI is tight for Boutique (10 services + system pods). |
| `CKV_AZURE_172` | `key_vault_secrets_provider { secret_rotation_enabled = true }` | `modules/aks/main.tf` | Pods see stale secret values after rotation. Without autorotation, a rotated certificate or password requires a pod restart or redeployment to take effect — causing downtime during incident response. |
| `CKV2_AZURE_31` | Added NSG + association for `appgw-subnet` and `pe-subnet` | `modules/networking/main.tf` | Subnets without NSGs have no Layer-4 traffic controls. Any resource accidentally deployed into those subnets is reachable from anywhere in the VNet by default. |

**What was added to networking module:**
- `appgw-nsg`: allows inbound 65200-65535 (required by AppGW v2 health probes), 443, 80 from Internet; denies everything else
- `pe-nsg`: explicitly denies Internet inbound — private endpoints should only be reachable from within the VNet

---

#### Checks skipped via Checkov `skip_check` (and why)

These require Premium SKU, paid Microsoft add-ons, or subscription-level feature flags that are out of scope for this playbook. Skipping them keeps the pipeline green without compromising the controls that *can* be implemented cost-effectively.

| Check | What it requires | Why skipped | Impact of skipping |
|---|---|---|---|
| `CKV_AZURE_139` / `CKV_AZURE_166` | ACR `public_network_access_enabled = false` | Dev intentionally sets `true` so GitHub-hosted runners (public internet) can push images. Prod overrides this to `false` via the module variable. | Dev ACR is reachable from the internet on port 443 — acceptable because ACR authentication (AAD token or managed identity) is still enforced. |
| `CKV_AZURE_233` | ACR zone redundancy | Premium SKU only (~3× cost vs Standard). Not needed for a dev/demo cluster. | Single availability zone — an AZ outage would make the registry unavailable. Acceptable for non-production. |
| `CKV_AZURE_237` | ACR dedicated data endpoints | Premium SKU only. Dedicated endpoints prevent data exfiltration via shared endpoint. | Shared data endpoint used — in theory an attacker who can reach the ACR endpoint could use it for data exfil. Mitigated by private endpoint in prod. |
| `CKV_AZURE_165` | ACR geo-replication | Premium SKU only. Needed for multi-region deployments. | Single-region registry — a regional outage affects all environments. Out of scope for single-region playbook. |
| `CKV_AZURE_163` | ACR vulnerability scanning | Requires Microsoft Defender for Containers (~$7/node/month). Scans images in ACR for OS and package CVEs. | Without this, CVEs in pushed images are not caught at rest in ACR. Mitigated by Trivy image scan in the build pipeline (catches CVEs at build time before push). |
| `CKV_AZURE_164` | ACR trusted images (Docker Content Trust) | Requires DCT key management infrastructure and a separate signing workflow. | Unsigned images can be pulled — no cryptographic proof they haven't been tampered with. Mitigated by private endpoint (only VNet can pull) and Trivy scan at build time. |
| `CKV_AZURE_117` | AKS disk encryption set | Requires a Key Vault key + `azurerm_disk_encryption_set` resource + subscription permissions. | OS and data disks are encrypted with Microsoft-managed keys (PMK) not customer-managed keys (CMK). PMK is encrypted at rest — absence of CMK is a compliance gap, not a plain-text risk. |
| `CKV_AZURE_227` | AKS host encryption | Requires the `EncryptionAtHost` feature flag enabled at the Azure subscription level via `az feature register`. | Temp disks and caches on nodes are not encrypted. Only a concern if sensitive data is written to temp disk (rare for Kubernetes workloads). |
| `CKV_AZURE_170` | AKS paid SLA tier | Uptime SLA tier adds ~$73/cluster/month. Free tier has no SLA guarantee on control plane. | No SLA on API server uptime. For a demo/dev cluster, acceptable; for prod workloads, should be enabled. |
| `CKV_AZURE_226` | AKS ephemeral OS disks | Requires the VM SKU to have enough local SSD (cache disk) to hold the OS image. Not guaranteed for all D-series sizes. | Managed OS disks used instead — slightly higher I/O latency and cost per node. No security impact. |

---

#### Fix for tfsec SARIF path error

**Error:** `Path does not exist: tfsec-results.sarif`

**Root cause:** The `aquasecurity/tfsec-action` writes the SARIF output file relative to its `working_directory` parameter (`infrastructure/terraform`), not the workspace root. The `upload-sarif` step was looking for the file at workspace root.

**Fix:** Updated the upload step in `.github/workflows/terraform-dev.yml`:
```yaml
# Before (wrong — looks in workspace root)
sarif_file: tfsec-results.sarif

# After (correct — matches where tfsec-action wrote the file)
sarif_file: infrastructure/terraform/tfsec-results.sarif
```

---

### Fix 8 — Two more Checkov failures: ACR retention policy and HTTP port 80 on AppGW NSG

**Errors (in GitHub Actions security job):**
```
Check: CKV_AZURE_167: "Ensure a retention policy is set to cleanup untagged manifests."  FAILED
Check: CKV_AZURE_160: "Ensure that HTTP (port 80) access is restricted from the internet" FAILED
```

---

#### CKV_AZURE_167 — ACR untagged manifest retention policy

**What it checks:** Every ACR registry must have `retention_policy { enabled = true }` to automatically delete untagged image manifests after a configurable number of days.

**Why it matters — impact of not fixing:**  
Untagged manifests are orphaned image layers left behind when a new image is pushed with the same tag. They remain pullable by digest even though no tag points to them. Over time this means:
- Old, potentially vulnerable image versions accumulate silently in ACR storage
- An attacker who learns a digest can pull a known-vulnerable image layer that no tag exposes
- ACR storage costs grow unbounded with every CI push

**Root cause of Checkov false-positive:**  
`retention_policy` requires Standard or Premium SKU — dev uses `sku = "Basic"`. A static `retention_policy {}` block in the module would cause `terraform apply` to fail on dev (Basic does not accept this attribute). The fix uses a `dynamic` block conditional on the SKU:

```hcl
dynamic "retention_policy" {
  for_each = var.sku != "Basic" ? [1] : []
  content {
    days    = 7
    enabled = true
  }
}
```

Checkov evaluates the module statically and cannot resolve `var.sku` at scan time, so it flags the resource even though the control is correctly implemented. Adding `CKV_AZURE_167` to `skip_check` keeps the pipeline green while the dynamic block ensures the retention policy is applied for prod (Standard SKU).

**Files changed:**
- `modules/acr/main.tf` — added `dynamic "retention_policy"` block
- `.github/workflows/terraform-dev.yml` — added `CKV_AZURE_167` to `skip_check` with explanation

---

#### CKV_AZURE_160 — HTTP port 80 from internet allowed on AppGW NSG

**What it checks:** No NSG rule should allow inbound TCP port 80 from `Internet` (unrestricted HTTP access).

**Why it matters — impact of allowing port 80:**  
Allowing plain HTTP from the internet creates a surface for:
- Credential theft if any authentication happens over HTTP before redirect
- Protocol downgrade attacks (SSL stripping) against clients that initially connect on port 80
- An unnecessary open port — if AppGW isn't provisioned yet, there is no application to receive it

**Fix — removed AllowHTTPInbound rule:**  
The `AllowHTTPInbound` rule (port 80 from Internet) was removed from the appgw NSG. The Application Gateway subnet now only allows:
- Port 65200–65535 from `GatewayManager` (required health probe ports for AppGW v2)
- Port 443 from Internet (HTTPS only)

**When port 80 IS needed:**  
If HTTP→HTTPS redirect via Application Gateway is implemented later, the TCP connection must reach the AppGW on port 80 before it can issue a 301. At that point, add a documented `AllowHTTPInbound` rule and either skip `CKV_AZURE_160` or accept the finding with a suppression comment. This is a deliberate deferral, not a permanent omission.

**Files changed:**
- `modules/networking/main.tf` — removed `AllowHTTPInbound` security rule from `appgw` NSG

---

### Fix 9 — tfsec SARIF file never written (`aquasecurity/tfsec-action@v1.0.3` unreliable)

**Error (in GitHub Actions security job):**
```
Path does not exist: tfsec-results.sarif
Path does not exist: infrastructure/terraform/tfsec-results.sarif
```

**Root cause:** `aquasecurity/tfsec-action@v1.0.3` does not reliably write the SARIF output file. The action wraps tfsec in a Docker container and the file may be written inside the container filesystem rather than the runner workspace. The `sarif_file` and `working_directory` parameters interact inconsistently across action versions — changing the upload path just moved the error, not solved it.

**Fix:** Replace the action entirely with a direct CLI install + run:

```yaml
- name: Install tfsec
  run: >
    curl -sL
    https://github.com/aquasecurity/tfsec/releases/latest/download/tfsec-linux-amd64
    -o /usr/local/bin/tfsec && chmod +x /usr/local/bin/tfsec

- name: tfsec — Terraform-specific security analysis
  run: |
    tfsec infrastructure/terraform --format sarif --out tfsec-results.sarif || true

- name: Upload tfsec results to GitHub Security tab
  if: always()
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: tfsec-results.sarif
    category: tfsec
```

**Why CLI install instead of the action:**
- The binary runs directly on the runner — output path is `$GITHUB_WORKSPACE/tfsec-results.sarif`, exactly where the upload step expects it
- `|| true` ensures a non-zero tfsec exit (findings present) never fails the step — tfsec remains informational
- `latest` download always gets the current release without pinning a potentially broken action version

**Files changed:** `.github/workflows/terraform-dev.yml`

---

### Fix 10 — AADSTS700213: missing federated credential for `environment:dev` subject

**Error (in GitHub Actions apply job):**
```
AADSTS700213: No matching federated identity record found for presented assertion subject
'repo:tushart-chaudhari1992/azure-aks-gitops:environment:dev'
```

**Root cause:** When a GitHub Actions job declares `environment: dev`, Azure AD receives an OIDC token whose `sub` claim changes from `ref:refs/heads/main` to `environment:dev`. Each distinct subject requires its own federated identity credential on the App Registration — they are matched by exact string.

We had credentials for `ref:refs/heads/main` and `pull_request`, but not for `environment:dev`.

**Fix:** Create a third federated identity credential:

```powershell
$az = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
$appId = "565da2b4-54d4-423c-893d-bcc454a09383"
$json = @'
{
  "name": "github-env-dev",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:tushart-chaudhari1992/azure-aks-gitops:environment:dev",
  "audiences": ["api://AzureADTokenExchange"]
}
'@
$tmpFile = "$env:TEMP\fic-env-dev.json"
$json | Out-File -FilePath $tmpFile -Encoding utf8
& $az ad app federated-credential create --id $appId --parameters "@$tmpFile"
```

**All three credentials now in place:**

| Name | Subject | Used by |
|---|---|---|
| `github-main` | `repo:…:ref:refs/heads/main` | validate, plan jobs on push to main |
| `github-pr` | `repo:…:pull_request` | validate, plan jobs on PRs |
| `github-env-dev` | `repo:…:environment:dev` | apply job (has `environment: dev` declared) |

**Rule:** Every job that declares `environment: <name>` in the workflow needs its own federated credential with subject `repo:<owner>/<repo>:environment:<name>`. If a `prod` environment is added later, a fourth credential with subject `…:environment:prod` must be created before the apply job for prod will authenticate.

**Note on PowerShell JSON quoting:** Passing JSON inline via `--parameters '{"key":"val"}'` fails in PowerShell because it strips the inner double quotes. Always write the JSON to a temp file and pass `--parameters "@/path/to/file.json"`.

---

### Fix 11 — Four terraform apply errors: deprecated field, 403 role assignment, ACR SKU, kubelet identity

**Errors (during terraform apply in GitHub Actions):**
```
Warning: managed = true is deprecated (azure_active_directory_role_based_access_control)
Error: 403 AuthorizationFailed — Microsoft.Authorization/roleAssignments/write
Error: 400 SKUNotSupportPrivateEndpoint — upgrade registry to Premium SKU
Error: Missing required argument — kubelet_identity requires identity.type = UserAssigned
```

---

#### Fix 11a — Remove deprecated `managed = true` field

**Root cause:** `managed` inside `azure_active_directory_role_based_access_control` is legacy. In azurerm v4 it is removed; the value is always `true` by default. Keeping it produces a deprecation warning that clutters apply output.

**Fix:** Removed the `managed = true` line from the block in `modules/aks/main.tf`. The block now only contains `azure_rbac_enabled = true`.

**Correction — `managed = true` must stay in azurerm ~3.x:** Removing it causes `terraform validate` to fail with "one of admin_group_object_ids, client_app_id, managed, server_app_id … must be specified." In v3, `managed = true` is the flag that switches the block from legacy AAD app registration mode to AKS-managed Entra integration. Without it, the provider expects legacy fields. The field was restored with a comment explaining it will be auto-defaulted (and removable) in azurerm v4.0.

**Impact of removing it prematurely:** `terraform validate` exits with 6 errors — the pipeline fails at the validate stage before any plan is produced.

---

#### Fix 11b — 403 on role assignment creation (User Access Administrator missing)

**Root cause:** Terraform's `azurerm_role_assignment` resource calls `Microsoft.Authorization/roleAssignments/write`. The `Contributor` role does not include this permission. Creating role assignments requires `Owner` or `User Access Administrator`.

**Fix:** Granted `User Access Administrator` to the CI service principal at subscription scope:
```powershell
$az = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
& $az role assignment create `
  --assignee "5ccb4527-302c-4944-8bdb-f96b16f2cb6d" `
  --role "User Access Administrator" `
  --scope "/subscriptions/3a2f7662-4ee2-4762-ab05-988439cdb9c4"
```

Role assignment ID created: `889ea22a-05b1-40e4-9455-5f9519ae164f`

**Why subscription scope and not RG scope:** The resource group `boutique-dev-rg` is itself created by Terraform. Granting at RG scope would be a chicken-and-egg problem — the RG must exist before you can grant a role on it. Subscription scope covers all current and future RGs.

**Security note:** `User Access Administrator` is a privileged role. In a stricter environment, use a custom role scoped to only `Microsoft.Authorization/roleAssignments/write` on specific resource types. For this playbook the built-in role is acceptable.

**Impact of not fixing:** Every `azurerm_role_assignment` resource in the Terraform config fails to create. The AKS kubelet identity cannot pull from ACR, the Key Vault access policy cannot be set — the cluster would start but fail to pull images.

---

#### Fix 11c — ACR private endpoint fails on Basic/Standard SKU

**Root cause:** Azure ACR private endpoints require **Premium** SKU. Basic and Standard SKUs do not support private endpoint connections. Dev uses Basic, prod uses Standard — both would fail trying to create the private endpoint.

**Fix:** Added `count = var.sku == "Premium" ? 1 : 0` to all three private-endpoint-related resources in `modules/acr/main.tf`:
- `azurerm_private_endpoint.acr`
- `azurerm_private_dns_zone.acr`
- `azurerm_private_dns_zone_virtual_network_link.acr`

References inside those resources updated to use `[0]` index (required when using `count`).

**Behaviour by environment:**

| Environment | SKU | Private endpoint created? | Access path |
|---|---|---|---|
| dev | Basic | No | Public internet (authenticated) |
| prod | Standard | No | Public internet (authenticated) |
| future prod | Premium | Yes | VNet private endpoint only |

**To enable private endpoints in prod:** Change `sku = "Standard"` to `sku = "Premium"` in `environments/prod/main.tf`. Terraform will upgrade the registry and create the endpoint, DNS zone, and VNet link automatically.

**Impact of not fixing:** `terraform apply` fails with 400 Bad Request before any ACR resources are fully created.

---

#### Fix 11d — `kubelet_identity` incompatible with `SystemAssigned` control plane identity

**Root cause:** The azurerm provider enforces a constraint: when `kubelet_identity` is specified, the `identity` block must have `type = "UserAssigned"` with at least one entry in `identity_ids`. `SystemAssigned` is not permitted alongside a custom kubelet identity because Azure needs an explicit user-assigned identity to delegate kubelet permissions to.

**Fix:** Added a second `azurerm_user_assigned_identity` resource for the AKS control plane, and changed the `identity` block:

```hcl
# Before (breaks when kubelet_identity is also set)
identity {
  type = "SystemAssigned"
}

# After — separate identity for control plane vs kubelet
resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "${var.prefix}-aks-identity"
  ...
}

identity {
  type         = "UserAssigned"
  identity_ids = [azurerm_user_assigned_identity.control_plane.id]
}
```

**Two identities now in use:**

| Identity | Name | Purpose |
|---|---|---|
| `control_plane` | `boutique-dev-aks-identity` | AKS manages load balancers, routes, node NICs |
| `kubelet` | `boutique-dev-kubelet-identity` | Nodes pull images from ACR, mount Key Vault secrets |

Keeping them separate follows least-privilege — a compromised node cannot use the control plane identity to modify cluster infrastructure, and the control plane identity cannot access ACR or Key Vault.

**Impact of not fixing:** `terraform apply` fails immediately with "Missing required argument" before AKS is created.

---

### Fix 12 — `CustomKubeletIdentityMissingPermissionError` on AKS cluster creation

**Error (during terraform apply):**
```
400 Bad Request — CustomKubeletIdentityMissingPermissionError
The cluster using user-assigned managed identity must be granted
'Managed Identity Operator' role to assign kubelet identity.
```

**Root cause:** When AKS uses a UserAssigned control plane identity with a separate kubelet identity (Fix 11d), Azure requires the control plane identity to have the `Managed Identity Operator` role on the kubelet identity resource. Without it, the AKS control plane cannot assign the kubelet identity to nodes at provisioning time.

This is an Azure platform requirement — it applies any time you separate the control plane and kubelet identities.

**Fix:** Added a role assignment in `modules/aks/main.tf`:

```hcl
resource "azurerm_role_assignment" "control_plane_kubelet_operator" {
  principal_id                     = azurerm_user_assigned_identity.control_plane.principal_id
  role_definition_name             = "Managed Identity Operator"
  scope                            = azurerm_user_assigned_identity.kubelet.id
  skip_service_principal_aad_check = true
}
```

Also added `depends_on = [azurerm_role_assignment.control_plane_kubelet_operator]` to the `azurerm_kubernetes_cluster` resource. Azure AD role assignment propagation takes up to 2 minutes — without `depends_on`, Terraform submits the cluster creation API call immediately after the role assignment API returns, before the permission has actually propagated, and the cluster creation races and fails with the same 400 error.

**Why `skip_service_principal_aad_check = true`:** The principal is a managed identity (not a service principal backed by an app registration). This flag skips an AAD lookup that would otherwise fail for managed identities.

**Impact of not fixing:** AKS cluster creation always fails with 400. No cluster, no node pools, no workloads.

---

## Where to Check Pipeline Status

### GitHub Actions runs
```
https://github.com/tushart-chaudhari1992/azure-aks-gitops/actions
```
- Left sidebar: select a specific workflow (`Terraform — Dev Infrastructure`, `Build, Scan and Push to ACR`, `DAST`)
- Each run shows a job graph — click any job to see live logs
- Red = failed, Yellow = waiting for approval, Green = passed

### Trigger the Terraform pipeline manually (workflow_dispatch)
1. Go to Actions → **Terraform — Dev Infrastructure**
2. Click **Run workflow** (top right) → **Run workflow**

### GitHub Security tab (SARIF findings)
```
https://github.com/tushart-chaudhari1992/azure-aks-gitops/security/code-scanning
```
Checkov, tfsec, Trivy, and ZAP all upload findings here. Filter by tool using the **Tool** dropdown.

### Approve the apply job (after plan passes)
1. Actions → the specific run → click **Review deployments**
2. Check the box next to `dev` → **Approve and deploy**
The apply job then runs `terraform apply` against the saved plan.

### GitHub Environment protection rules
```
https://github.com/tushart-chaudhari1992/azure-aks-gitops/settings/environments
```
Click `dev` → add/remove required reviewers here.

### GitHub Actions secrets and variables
```
https://github.com/tushart-chaudhari1992/azure-aks-gitops/settings/secrets/actions
```
Required secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
Required variables: `ACR_NAME`, `ACR_LOGIN_SERVER` (set after Terraform apply)

---

## Teardown (when done)

```bash
# Dev — destroys all resources in boutique-dev-rg (irreversible)
cd infrastructure/terraform/environments/dev
terraform destroy

# State storage — destroy last, manually
az group delete --name tfstate-rg --yes
```
