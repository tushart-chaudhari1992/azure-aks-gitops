# DO NOT commit real values here — use CI variable groups or Key Vault references
prefix   = "boutique-dev"
location = "eastus"

# Replace with your CI service principal object ID
ci_service_principal_object_id = "5ccb4527-302c-4944-8bdb-f96b16f2cb6d"

# AKS API server IP allowlist — only these CIDRs can run kubectl against the cluster.
# Update this when your public IP changes (run: curl ifconfig.me or Invoke-WebRequest api.ipify.org).
api_server_authorized_ip_ranges = ["223.233.84.73/32"]
