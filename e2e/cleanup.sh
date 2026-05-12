#!/usr/bin/env bash
# =============================================================================
# E2E Cleanup — removes all resources created by run.sh
# =============================================================================
set -euo pipefail

GIT_SERVER="${GIT_SERVER:-https://gitpop.apps.sno.msl.cloud}"
APP_NAME="${APP_NAME:-fortune-cookie}"
E2E_NS="${E2E_NS:-workshop-e2e}"
TEMPLATE_REPO_NAME="go-app-template"
GITPOP_BIN="/tmp/gitpop-e2e"

echo "=== E2E Cleanup ==="

# Argo CD Application
oc delete application "$APP_NAME" -n openshift-gitops --ignore-not-found && \
  echo "  ✅  ArgoCD Application deleted" || true

# App namespaces
for ns in "${APP_NAME}-build" "${APP_NAME}-dev" "$E2E_NS"; do
  oc delete namespace "$ns" --ignore-not-found && \
    echo "  ✅  Namespace $ns deleted" || true
done

# Git server repos (using gitpop or API if available)
if [[ -x "$GITPOP_BIN" ]]; then
  for repo in "$APP_NAME" "$TEMPLATE_REPO_NAME"; do
    curl -sf -X DELETE "${GIT_SERVER}/api/v1/repos/${repo}" 2>/dev/null && \
      echo "  ✅  Git repo $repo deleted" || \
      echo "  ⚠️   Could not delete Git repo $repo (may not exist)"
  done
fi

# Local temp dirs
rm -f "$GITPOP_BIN"
rm -rf /tmp/go-app-template.*

echo ""
echo "Cleanup complete."
