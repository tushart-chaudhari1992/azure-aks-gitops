# MCP Servers and Skills

This document covers the MCP servers and Claude Code skills configured for the azure-aks-gitops project, why each was chosen, and what it enables Claude to do.

---

## MCP Servers

MCP (Model Context Protocol) servers run as background processes and expose tools Claude can call directly during a session. The configuration lives at `.claude/settings.json` in this project — Claude loads it automatically when you open a session here.

Verify all servers are connected at the start of a session:
```
/mcp
```

---

### 1. HashiCorp Terraform MCP Server

**Package:** `@hashicorp/terraform-mcp-server`
**Official:** Yes — maintained by HashiCorp

**What it enables:**
- Run `terraform init`, `plan`, `apply`, `validate`, and `destroy` without leaving Claude
- Search the AzureRM and AzureAD provider documentation for resource schemas
- Look up Terraform Registry modules
- Run `terraform show` to inspect state

**Why this one over the awslabs Terraform server:**
The awslabs Terraform MCP server is deprecated. HashiCorp's official server is the current recommended replacement — it has the same capabilities with active maintenance and official support.

**Security note:** Claude will still follow the safe execution rules in CLAUDE.md — it will show the plan and ask for approval before running `terraform apply`.

**Example interactions:**
```
"Run terraform plan in infrastructure/terraform/environments/dev"
"What is the AzureRM resource for creating a private endpoint?"
"Show me the current Terraform state for the AKS cluster"
```

---

### 2. Kubernetes MCP Server

**Package:** `mcp-server-kubernetes` (community)
**Official:** Community — well-maintained, widely used

**What it enables:**
- List and inspect pods, deployments, services, and events across namespaces
- Stream pod logs directly into the conversation
- Apply Kubernetes manifests to the cluster
- Describe resource specs (equivalent to `kubectl describe`)
- Check rollout status and history

**Requirement:** `KUBECONFIG` must be set and point to a valid kubeconfig for the AKS cluster. Since the AKS API server is private, this only works from inside the VNet (self-hosted runner, jump box, or cloud shell).

**Why this matters for the project:** Rather than running `kubectl` commands manually to debug a failing pod, Claude can read the logs, check events, and propose a fix — all in one conversation.

**Example interactions:**
```
"Why is the cartservice pod in CrashLoopBackOff?"
"Show me the last 100 lines of logs from the frontend pod"
"Apply the updated deployment manifest to boutique-dev"
"What is the rollout history of the checkoutservice deployment?"
```

---

### 3. GitHub MCP Server

**Package:** `@modelcontextprotocol/server-github`
**Official:** Yes — Anthropic reference implementation

**What it enables:**
- Read and comment on pull requests
- View file diffs and commit history
- Create and update issues
- Search code across the repository
- Trigger workflow runs

**Setup:** Set `GITHUB_TOKEN` in your environment (a personal access token with `repo` scope, or a fine-grained token scoped to this repository).

**Why this is useful for a GitOps project:** In GitOps, the Git repo is the deployment mechanism. Being able to review a PR that updates image tags or Kustomize overlays — and understand what it will deploy — without leaving Claude is a natural fit.

**Example interactions:**
```
"Show me what changed in the last PR merged to main"
"Create an issue: prod sync is blocked because boutique-prod Application is OutOfSync"
"What commits touched the overlays/prod/kustomization.yaml file in the last month?"
```

---

### 4. Azure Cost Estimator

**Package:** `awslabs.aws-pricing-mcp-server` (adapted)
**Note:** This is the AWS pricing server — Azure does not yet have an equivalent official MCP server. For Azure cost estimates, Claude will use its built-in knowledge or direct you to the Azure Pricing Calculator. This entry is a placeholder; replace it with an Azure-native pricing server when one becomes available.

**Interim approach:** Ask Claude to estimate costs using the Azure pricing tables documented in `docs/system-design.md`. For precise quotes, use:
```
https://azure.microsoft.com/en-us/pricing/calculator/
```

---

## Pre-requisites for MCP Servers

### Node.js
All three active MCP servers use `npx`. Verify Node.js is installed:
```bash
node --version   # should be 18+
npx --version
```

### Environment variables
Set these before starting Claude Code:
```bash
# Windows (PowerShell)
$env:GITHUB_TOKEN = "ghp_your_token_here"
$env:KUBECONFIG = "C:\Users\<you>\.kube\config"   # path to your AKS kubeconfig

# Fetch the AKS kubeconfig (run once after terraform apply)
az aks get-credentials --resource-group boutique-dev-rg --name boutique-dev-aks
```

### Verify connectivity
```
/mcp
```
All servers should show `connected`. Common failures:

| Server | Failure reason | Fix |
|--------|---------------|-----|
| `kubernetes` | KUBECONFIG not set or cluster unreachable | Run `az aks get-credentials`; confirm you're on VPN or inside VNet |
| `github` | GITHUB_TOKEN not set or expired | Generate a new PAT at GitHub → Settings → Developer settings |
| `hashicorp.terraform` | npx not found | Install Node.js |

---

## Skills

Skills are domain-specific knowledge packs that give Claude deeper context for specific tools beyond its base training. Install them with the Claude Code CLI.

### How skills work in the current Claude Code version

Skills in the current Claude Code CLI are **built-in slash commands** — there is no `claude skills install` command or external registry. The skills available are fixed and invoked directly:

```
/security-review    # security review of pending changes
/review             # PR review
/simplify           # code quality review
/fewer-permission-prompts   # reduce permission prompts
/schedule           # schedule recurring agents
```

> Note: Older Claude Code documentation references `claude skills install terraform-skill`. This feature no longer exists in the current CLI. The slash commands above are the complete skills system as of April 2026.

### Which skills apply to this project

| Stage | Skill | When to run |
|-------|-------|------------|
| Before merging Terraform changes | `/security-review` | Catches open network rules, broad IAM, missing encryption |
| Before merging K8s or GitOps overlay PRs | `/review` | Reviews manifest changes before ArgoCD syncs them |
| After editing Terraform modules or pipelines | `/simplify` | Identifies repeated blocks, redundant resources |
| After a long working session with many prompts | `/fewer-permission-prompts` | Adds allowlist so safe read commands auto-approve |
| Setting up drift detection or cost alerts | `/schedule` | Create a recurring weekly agent |

---

## Impact on Workflow

With all MCP servers connected and the Terraform skill installed, a typical debugging session changes from:

**Without MCP:**
```
User: "The cartservice pod is crashing"
Claude: "Run kubectl describe pod <name> and paste the output here"
User: [pastes output]
Claude: [analyses]
```

**With MCP:**
```
User: "The cartservice pod is crashing"
Claude: [calls kubernetes MCP → reads pod events and logs directly]
Claude: "The pod is OOMKilled — the memory limit is 128Mi but the process is hitting 180Mi.
         Here's a patch to update the limit in the base manifest..."
```

The files themselves do not change — MCP servers change what Claude can observe and act on during the conversation.
