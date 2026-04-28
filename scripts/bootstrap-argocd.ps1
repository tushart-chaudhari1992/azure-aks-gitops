# Bootstrap ArgoCD on AKS dev cluster
# Run from repo root: .\scripts\bootstrap-argocd.ps1
#
# Prerequisites:
#   - kubectl installed and configured (az aks get-credentials already run)
#   - Azure Kubernetes Service RBAC Cluster Admin role assigned to your user
#
# Re-run safe: all steps are idempotent

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Step 1: Create argocd namespace ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

Write-Host ""
Write-Host "=== Step 2: Install ArgoCD v2.11.0 ==="
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.0/manifests/install.yaml

Write-Host ""
Write-Host "=== Step 3: Wait for ArgoCD server rollout (2-3 min) ==="
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m

Write-Host ""
Write-Host "=== Step 4: Configure insecure mode via ConfigMap ==="
# Use --patch-file to avoid PowerShell 5.1 JSON quoting issues
'{"data":{"server.insecure":"true"}}' | Out-File "$env:TEMP\cm-patch.json" -Encoding utf8
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge --patch-file "$env:TEMP\cm-patch.json"

Write-Host ""
Write-Host "=== Step 5: Restart server to pick up ConfigMap ==="
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=3m

Write-Host ""
Write-Host "=== Step 6: Expose ArgoCD UI via port-forward ==="
# Opens in a new PowerShell window — keep it open while using the UI
Start-Process powershell -ArgumentList "-NoExit", "-Command", "kubectl port-forward svc/argocd-server -n argocd 8080:80"
Write-Host "Port-forward running in new window — do not close it"

Write-Host ""
Write-Host "=== Step 7: Apply Boutique dev Application manifest ==="
kubectl apply -f https://raw.githubusercontent.com/tushart-chaudhari1992/azure-aks-gitops/main/gitops/argocd/apps/boutique-dev.yaml

Write-Host ""
Write-Host "=== Step 8: Get admin password ==="
$encoded = kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}"
$password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))

Write-Host ""
Write-Host "============================================"
Write-Host "  ArgoCD is ready!"
Write-Host "  URL:      http://localhost:8080"
Write-Host "  Username: admin"
Write-Host "  Password: $password"
Write-Host "============================================"
Write-Host ""
Write-Host "NOTE: After every cluster recreate, reassign RBAC role:"
Write-Host '  $scope = "/subscriptions/3a2f7662-4ee2-4762-ab05-988439cdb9c4/resourceGroups/boutique-dev-rg/providers/Microsoft.ContainerService/managedClusters/boutique-dev-aks"'
Write-Host '  az role assignment create --assignee "968ca43e-a6c5-4f87-945c-5f5fd3d95a53" --role "Azure Kubernetes Service RBAC Cluster Admin" --scope $scope'
