#!/bin/bash
set -e

# Fix ArgoCD server startup after bad kubectl patch attempts.
#
# Run via az aks command invoke --file (not --command) to avoid shell escaping corruption:
#
#   az aks command invoke \
#     --resource-group boutique-dev-rg \
#     --name boutique-dev-aks \
#     --file scripts/fix-argocd.sh \
#     --command "bash fix-argocd.sh"
#
# What this does:
#   1. Sets server.insecure=true in argocd-cmd-params-cm (ArgoCD reads this on startup)
#   2. Sets command: ["argocd-server"] in the Deployment — the v2.11 image has no Docker CMD,
#      tini needs a PROGRAM to exec or it prints its help and exits
#   3. Restarts the Deployment and waits for rollout to complete

kubectl patch configmap argocd-cmd-params-cm -n argocd \
  -p '{"data":{"server.insecure":"true"}}'

kubectl patch deployment argocd-server -n argocd \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","command":["argocd-server"]}]}}}}'

kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=3m
