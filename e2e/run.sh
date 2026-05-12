#!/usr/bin/env bash
# =============================================================================
# E2E Workshop Validation Script
# =============================================================================
# Validates the full workshop flow end-to-end:
#   Phase 1 — Platform Engineer: create the Go app template on the Git server
#   Phase 2 — Developer simulation: deploy a container, install deps, run OpenCode
#   Phase 3 — Validate: repos, generated files, image build, GitOps, live route
#
# Prerequisites:
#   - oc is logged in with cluster-admin
#   - GIT_SERVER is set (or defaults to the value below)
#   - GPU InferenceService qwen36 is Ready in namespace llm-inference
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
GIT_SERVER="${GIT_SERVER:-https://gitpop.apps.sno.msl.cloud}"
APP_NAME="${APP_NAME:-fortune-cookie}"
E2E_NS="${E2E_NS:-workshop-e2e}"
TEMPLATE_URL="${TEMPLATE_URL:-https://github.com/fjcloud/go-app-template}"
LLM_URL="http://qwen36-predictor.llm-inference.svc.cluster.local:8080/v1"
LLM_MODEL="qwen36"
GITPOP_BIN="/tmp/gitpop-e2e"   # still needed for the gitpop helper function
DEV_POD="e2e-developer"
DEV_IMAGE="quay.io/devfile/universal-developer-image:latest"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()    { echo -e "\n${BOLD}${BLUE}══ $* ${NC}"; }
ok()      { echo -e "  ${GREEN}✅  $*${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠️   $*${NC}"; }
fail()    { echo -e "  ${RED}❌  $*${NC}"; exit 1; }
info()    { echo -e "  ${CYAN}→  $*${NC}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
require() {
  command -v "$1" &>/dev/null || fail "Required tool not found: $1"
}

check_llm_ready() {
  local ready
  ready=$(oc get inferenceservice qwen36 -n llm-inference \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$ready" == "True" ]]
}

gitpop_repo_exists() {
  # Use git smart HTTP protocol to check repo existence — gitpop has no search API
  local url=$1
  curl -sf "${url}/info/refs?service=git-upload-pack" 2>/dev/null \
    | grep -q "git-upload-pack"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"

require oc
require curl
require git

info "Cluster: $(oc whoami --show-server)"
info "User:    $(oc whoami)"
info "Git server: $GIT_SERVER"

oc cluster-info &>/dev/null || fail "Not connected to a cluster"
check_llm_ready || warn "LLM InferenceService not Ready — deploy steps will still run but LLM prompts may fail"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Platform Engineer: verify the pre-initialized template repository
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 1: Platform Engineer — Verify template repository"

# The template is pre-initialized on GitHub at fjcloud/go-app-template.
# Platform Engineers share TEMPLATE_URL with developers as the DevSpaces launch URL.
info "Template URL: $TEMPLATE_URL"

if curl -sf --max-time 10 "${TEMPLATE_URL}/archive/main.tar.gz" -o /dev/null 2>/dev/null; then
  ok "Template repository reachable at $TEMPLATE_URL"
else
  warn "Template repository not reachable (network issue?) — continuing with cached clone"
fi

ok "Template repository: $TEMPLATE_URL"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Developer simulation: deploy a pod, install deps, run OpenCode
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 2: Developer simulation — deploy container"

oc new-project "$E2E_NS" 2>/dev/null || oc project "$E2E_NS"

# Replicate the rights a regular OpenShift user has:
#   self-provisioner (cluster-scoped) — lets oc new-project work;
#   the project admission template automatically grants admin on every project the SA creates.
oc adm policy add-cluster-role-to-user self-provisioner \
  -z default -n "$E2E_NS" 2>/dev/null || true

# Platform Engineer one-time setup (mirrors lab_2_operators):
# No cluster Argo CD config needed — each developer creates their own ArgoCD
# instance in their ${APP}-dev namespace via the openshift-gitops-operator.
# The operator must be pre-installed (lab_2_operators prerequisite).
info "Developer Argo CD model: each dev owns their ArgoCD instance in \${APP}-dev"

# No anyuid — the dev simulation pod and app both run under restricted-v2 SCC

info "Launching developer simulation pod..."
oc delete pod "$DEV_POD" -n "$E2E_NS" --ignore-not-found
oc run "$DEV_POD" \
  --image="$DEV_IMAGE" \
  --restart=Never \
  --namespace="$E2E_NS" \
  --env="GIT_SERVER=$GIT_SERVER" \
  --env="TEMPLATE_URL=$TEMPLATE_URL" \
  --env="APP_NAME=$APP_NAME" \
  --env="LLM_URL=$LLM_URL" \
  --env="LLM_MODEL=$LLM_MODEL" \
  --env="HOME=/home/user" \
  --env="PATH=/home/user/.opencode/bin:/home/user/.local/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -- sleep infinity

info "Waiting for pod to be Running..."
oc wait pod/"$DEV_POD" -n "$E2E_NS" \
  --for=condition=Ready --timeout=120s
ok "Pod $DEV_POD is Running"

# Convenience alias
POD_EXEC="oc exec $DEV_POD -n $E2E_NS --"

# ── Install dependencies inside the pod ───────────────────────────────────────
step "Phase 2a: Install OpenCode, gitpop, and Ansible inside developer pod"

$POD_EXEC bash -c "
  set -e
  echo '→ Installing OpenCode...'
  curl -fsSL https://opencode.ai/install | bash
  echo '→ Installing gitpop...'
  mkdir -p \$HOME/.local/bin
  curl -fsSL \"\$GIT_SERVER/dl/gitpop?os=linux&arch=amd64\" \
    -o \$HOME/.local/bin/gitpop
  chmod +x \$HOME/.local/bin/gitpop
  echo '→ Installing Ansible...'
  pip install --quiet ansible 2>/dev/null
  echo '→ Verifying tools...'
  opencode --version
  gitpop --version || gitpop help | head -3
  ansible --version | head -1
  echo 'Dependencies OK'
"
ok "OpenCode, gitpop, and Ansible installed in pod"

# ── Clone template and set up workspace ───────────────────────────────────────
step "Phase 2b: Clone template and configure workspace"

$POD_EXEC bash -c "
  set -e
  git clone \$TEMPLATE_URL ~/\$APP_NAME
  cd ~/\$APP_NAME
  git config user.email 'dev@workshop.local'
  git config user.name 'E2E Developer'
  ls -la
  echo '--- AGENTS.md preview ---'
  head -20 AGENTS.md
"
ok "Template cloned to ~/\$APP_NAME in pod"

# ── Run OpenCode: Build agent ─────────────────────────────────────────────────
step "Phase 2c: OpenCode — Build agent (generate the Fortune Cookie app)"

info "Sending build prompt to OpenCode (this takes 2-5 minutes)..."

# opencode --message runs non-interactively with the given prompt
OPENCODE_LOG="/tmp/opencode-build.log"

$POD_EXEC bash -c "
  cd ~/\$APP_NAME

  opencode run \
    'Implement a Fortune Cookie web application as defined in AGENTS.md.

Generate these files:
1. main.go — HTTP server on port 8080
   - GET /      returns an HTML page showing a random fortune cookie message
                (hard-code at least 10 messages in a slice)
   - GET /healthz returns {\"status\":\"ok\"}
2. go.mod — module: fortune-cookie, go 1.22
3. Dockerfile — use the exact two-stage template from AGENTS.md
   (ubi9/go-toolset builder, WORKDIR /tmp/build, -buildvcs=false, ubi9/ubi-minimal runtime, USER 1001)

The deploy/base/ manifests are already in the repository — do not regenerate them.

After writing all files, run:
  CGO_ENABLED=0 go build -buildvcs=false -o /dev/null .

Show the build output. Fix any compile errors before finishing.' \
  2>&1 | tee /tmp/opencode-build.log
" || warn "OpenCode build exited non-zero — check /tmp/opencode-build.log"

ok "OpenCode build session complete"

# ── Run OpenCode: Deploy agent ────────────────────────────────────────────────
step "Phase 2d: Deploy — run devfile task scripts"
# The deploy scripts ship inside the template and are the same scripts DevSpaces
# exposes as named Tasks. The e2e just calls them directly — same code, same result.

info "Playbook git-push — create app Git repository..."
$POD_EXEC bash -lc "
  cd ~/\$APP_NAME
  ansible-playbook scripts/git-push.yml
" 2>&1 | tee /tmp/deploy-git.log || warn "git-push playbook failed — see /tmp/deploy-git.log"

APP_REPO_URL=$($POD_EXEC bash -lc "
  cd ~/\$APP_NAME 2>/dev/null && git remote get-url origin 2>/dev/null || echo ''
" 2>/dev/null | tr -d '\r\n' || echo "")
info "App repo: ${APP_REPO_URL:-<not captured>}"

info "Playbook build-image — build container image with OpenShift Pipelines..."
$POD_EXEC bash -lc "
  cd ~/\$APP_NAME
  ansible-playbook scripts/build-image.yml
" 2>&1 | tee /tmp/deploy-build.log || warn "build-image playbook failed — see /tmp/deploy-build.log"

info "Playbook gitops-deploy — deploy developer-owned Argo CD + Application..."
$POD_EXEC bash -lc "
  cd ~/\$APP_NAME
  ansible-playbook scripts/gitops-deploy.yml
" 2>&1 | tee /tmp/deploy-gitops.log || warn "gitops-deploy playbook failed — see /tmp/deploy-gitops.log"

ok "OpenCode deploy session complete"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Validation
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 3: Validation"

FAILURES=0

check() {
  local label=$1; shift
  if eval "$@" &>/dev/null; then
    ok "$label"
  else
    warn "FAIL: $label"
    FAILURES=$((FAILURES + 1))
  fi
}

# 3a — Files generated in the pod
step "Phase 3a: Generated files"

check "main.go exists" \
  "$POD_EXEC test -f /home/user/$APP_NAME/main.go"

check "go.mod exists" \
  "$POD_EXEC test -f /home/user/$APP_NAME/go.mod"

check "Dockerfile exists" \
  "$POD_EXEC test -f /home/user/$APP_NAME/Dockerfile"

check "deploy/base/deployment.yaml exists" \
  "$POD_EXEC test -f /home/user/$APP_NAME/deploy/base/deployment.yaml"

check "deploy/base/route.yaml exists" \
  "$POD_EXEC test -f /home/user/$APP_NAME/deploy/base/route.yaml"

check "Binary compiles without errors" \
  "$POD_EXEC bash -c 'cd /home/user/$APP_NAME && PATH=/usr/local/go/bin:\$PATH CGO_ENABLED=0 go build -o /dev/null .'"

# 3b — Git repository on Git server
step "Phase 3b: Git server repository"

info "Template repo URL: ${TEMPLATE_URL}"
info "App repo URL:      ${APP_REPO_URL:-<not captured>}"

check "Template repo exists on Git server (git smart HTTP)" \
  "curl -sf '${TEMPLATE_URL}/info/refs?service=git-upload-pack' | grep -q git-upload-pack"

if [[ -n "$APP_REPO_URL" ]]; then
  check "App repo '${APP_NAME}' exists on Git server" \
    "curl -sf '${APP_REPO_URL}/info/refs?service=git-upload-pack' | grep -q git-upload-pack"

  check "App repo has main.go committed" \
    "git ls-remote '${APP_REPO_URL}' HEAD 2>/dev/null | grep -q '.'"
else
  warn "FAIL: App repo URL not captured — deploy step may have failed"
  FAILURES=$((FAILURES + 1))
fi

# 3c — Tekton Pipeline build
step "Phase 3c: OpenShift Pipelines (Tekton) image build"

check "Build namespace ${APP_NAME}-build exists" \
  "oc get namespace ${APP_NAME}-build"

check "Tekton Pipeline 'build-app' created" \
  "oc get pipeline build-app -n ${APP_NAME}-build"

check "At least one PipelineRun succeeded" \
  "oc get pipelinerun -n ${APP_NAME}-build --no-headers 2>/dev/null | grep -q Succeeded"

# The image is pushed directly to internal registry by buildah (no ImageStream)
check "Image exists in internal registry" \
  "oc get imagestreamtag ${APP_NAME}:latest -n ${APP_NAME}-build 2>/dev/null || \
   oc get pipelinerun -n ${APP_NAME}-build --no-headers 2>/dev/null | grep -q Succeeded"

# 3d — Developer-owned Argo CD
step "Phase 3d: Developer-owned Argo CD"

check "Dev namespace ${APP_NAME}-dev exists" \
  "oc get namespace ${APP_NAME}-dev"

check "ArgoCD instance created in ${APP_NAME}-dev" \
  "oc get argocd argocd -n ${APP_NAME}-dev"

check "Argo CD Application '${APP_NAME}' created" \
  "oc get application ${APP_NAME} -n ${APP_NAME}-dev"

# Wait for Argo CD to sync before checking deployment (up to 4 min)
info "Waiting for developer Argo CD to sync..."
for i in $(seq 1 24); do
  SYNC=$(oc get application "${APP_NAME}" -n "${APP_NAME}-dev" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  [[ "$SYNC" == "Synced" ]] && break
  sleep 10
done

check "Deployment '${APP_NAME}' is available" \
  "oc get deployment ${APP_NAME} -n ${APP_NAME}-dev \
   -o jsonpath='{.status.availableReplicas}' | grep -qE '[1-9]'"

# 3e — Live application
step "Phase 3e: Live application"

APP_ROUTE=$(oc get route "${APP_NAME}" -n "${APP_NAME}-dev" \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [[ -z "$APP_ROUTE" ]]; then
  warn "FAIL: Route '${APP_NAME}' not found in ${APP_NAME}-dev"
  FAILURES=$((FAILURES + 1))
else
  ok "Route: https://${APP_ROUTE}"

  check "/healthz returns {\"status\":\"ok\"}" \
    "curl -sk https://${APP_ROUTE}/healthz | grep -q 'ok'"

  check "/ returns HTML with a fortune" \
    "curl -sk https://${APP_ROUTE}/ | grep -iq 'fortune\|cookie\|luck\|wisdom'"
fi

# 3f — LLM smoke test (direct API call, no OpenCode)
step "Phase 3f: LLM API smoke test"

LLM_RESP=$(oc exec "$DEV_POD" -n "$E2E_NS" -- bash -c "
  curl -sf '${LLM_URL}/chat/completions' \
    -H 'Content-Type: application/json' \
    -d '{
      \"model\": \"${LLM_MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: HELLO_E2E\"}],
      \"max_tokens\": 20,
      \"chat_template_kwargs\": {\"enable_thinking\": false}
    }' | python3 -c \"import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])\"
" 2>/dev/null || echo "")

if echo "$LLM_RESP" | grep -q "HELLO_E2E"; then
  ok "LLM responds correctly: $LLM_RESP"
else
  warn "FAIL: LLM did not return expected response (got: '${LLM_RESP}')"
  FAILURES=$((FAILURES + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
step "Summary"

echo ""
echo -e "  Template repo : ${CYAN}${TEMPLATE_URL}${NC}"
echo -e "  App repo      : ${CYAN}${GIT_SERVER}/${APP_NAME}${NC}"
echo -e "  App route     : ${CYAN}https://${APP_ROUTE:-<not found>}${NC}"
echo -e "  Argo CD (dev) : ${CYAN}https://$(oc get route argocd-server -n ${APP_NAME}-dev -o jsonpath='{.spec.host}' 2>/dev/null || echo '<not deployed>')${NC}"
echo ""

if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All checks passed — workshop deployment is valid ✅${NC}"
else
  echo -e "${RED}${BOLD}$FAILURES check(s) failed — review warnings above ❌${NC}"
  exit 1
fi
