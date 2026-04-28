#!/bin/bash
set -e

# Configure ArgoCD server insecure mode via ConfigMap.
#
# The ArgoCD v2.11 image runs: tini -- /usr/local/bin/argocd-server (full path as Docker CMD).
# Setting k8s command: ["argocd-server"] overrides tini and passes the full path as a subcommand
# argument, causing: "unknown command /usr/local/bin/argocd-server for argocd-server".
# Solution: patch only the ConfigMap — ArgoCD reads server.insecure on startup and adds
# --insecure itself. No Deployment spec changes needed.
#
# PowerShell equivalent (use --patch-file to avoid PS5 JSON quoting issues):
#   '{"data":{"server.insecure":"true"}}' | Out-File "$env:TEMP\cm-patch.json" -Encoding utf8
#   kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge --patch-file "$env:TEMP\cm-patch.json"
#   kubectl rollout restart deployment/argocd-server -n argocd
#   kubectl rollout status deployment/argocd-server -n argocd --timeout=3m

kubectl patch configmap argocd-cmd-params-cm -n argocd \
  -p '{"data":{"server.insecure":"true"}}'

kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=3m
