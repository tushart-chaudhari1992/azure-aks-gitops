# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Safe Execution Mode

Before every action, explain in 1–2 sentences **what** you are doing and **why** — not just the command, but the reason it is needed and the expected outcome.

## Explicit Permission for Changes

Always ask for explicit approval before:
- Modifying or updating any existing file, resource, or configuration
- Deleting any file, resource, or infrastructure component
- Running `terraform apply` or `kubectl apply` against any environment

State clearly what will change and what will be affected before proceeding.

## Cost-Incurring Actions

Before any action that provisions, scales, or modifies billable Azure resources (AKS nodes, ACR, private endpoints, load balancers), explain the cost impact and wait for approval.

## Security Best Practices

For every infrastructure or config change, identify security implications and explain the control being applied. Flag any deviation from:
- Least-privilege IAM / RBAC
- Private endpoints over public access
- Managed identity over service principal credentials
- No secrets in Git or Kubernetes manifests

## Project Structure

```
azure-aks-gitops/
├── docs/system-design.md          ← Architecture decisions and trade-offs — read this first
├── infrastructure/terraform/
│   ├── modules/                   ← networking, aks, acr, keyvault — reusable modules
│   └── environments/dev|prod/     ← environment entry points, run terraform here
├── kubernetes/
│   ├── base/                      ← upstream service manifests, environment-agnostic
│   └── overlays/dev|prod/         ← kustomize overlays; CI updates image tags here
├── gitops/argocd/
│   ├── install/                   ← ArgoCD install kustomization
│   └── apps/                      ← ArgoCD Application manifests, one per environment
├── .github/workflows/             ← GitHub Actions: image build + push + tag update
└── .azuredevops/pipelines/        ← Azure DevOps: Terraform infra + image build (ADO variant)
```

## Git Commits

- Never include `Co-Authored-By: Claude` or any Claude/AI attribution in commit messages
- Use only the subject line and body describing what changed and why — no trailers

## Key Conventions

- **Image tags**: always `sha-<git-commit-sha>` — never `latest` in a real deployment
- **Terraform**: always run `plan` first; `apply` requires explicit approval; never run `destroy` without confirmation
- **Namespace**: `boutique-dev` for dev, `boutique-prod` for prod
- **ArgoCD**: dev syncs automatically; prod requires manual sync in the ArgoCD UI
- **Private endpoints**: ACR and Key Vault have no public endpoints — all access is via the VNet
- **Secrets**: never in Git; all secrets live in Azure Key Vault, mounted via CSI driver

## Terraform Workflow

```bash
cd infrastructure/terraform/environments/dev   # or prod
terraform init
terraform plan
# Review the plan output, then get approval before applying
terraform apply
```

## ArgoCD Bootstrap (first time only)

```bash
kubectl create namespace argocd
kubectl apply -k gitops/argocd/install/
# Wait for ArgoCD pods to be ready, then apply the Application manifests
kubectl apply -f gitops/argocd/apps/boutique-dev.yaml
kubectl apply -f gitops/argocd/apps/boutique-prod.yaml
```

## MCP Servers

Configuration is in `.claude/settings.json`. Three servers are configured:

| Server | Package | What it enables |
|--------|---------|----------------|
| `hashicorp.terraform` | `@hashicorp/terraform-mcp-server` | Run terraform commands, search AzureRM provider docs |
| `kubernetes` | `mcp-server-kubernetes` | Read pod logs, inspect resources, apply manifests |
| `github` | `@modelcontextprotocol/server-github` | Read PRs, diffs, issues — useful for GitOps PR review |

Verify all are connected at session start: `/mcp`

**Required env vars:** `GITHUB_TOKEN`, `KUBECONFIG` (pointing to the AKS cluster kubeconfig).

Full setup guide, troubleshooting, and skill recommendations: `docs/mcp-and-skills.md`
