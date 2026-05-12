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
TEMPLATE_REPO_NAME="go-app-template"
LLM_URL="http://qwen36-predictor.llm-inference.svc.cluster.local:8080/v1"
LLM_MODEL="qwen36"
GITPOP_BIN="/tmp/gitpop-e2e"
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
# PHASE 1 — Platform Engineer: create the Go app template
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 1: Platform Engineer — Bootstrap template repository"

info "Installing gitpop CLI..."
curl -fsSL "${GIT_SERVER}/dl/gitpop?os=linux&arch=amd64" -o "$GITPOP_BIN"
chmod +x "$GITPOP_BIN"
ok "gitpop installed at $GITPOP_BIN"

TEMPLATE_WORKDIR=$(mktemp -d /tmp/go-app-template.XXXXXX)
info "Working in $TEMPLATE_WORKDIR"
cd "$TEMPLATE_WORKDIR"

git init -b main
git config user.email "platform@workshop.local"
git config user.name "Platform Engineer"

# ── AGENTS.md ─────────────────────────────────────────────────────────────────
info "Writing AGENTS.md..."
cat > AGENTS.md << 'EOF'
# AGENTS.md — Go App Platform Conventions

You are running inside an OpenShift DevSpace on ROSA. `oc` is authenticated.
`$GIT_SERVER` and `$APP_NAME` are set in the terminal.

## Files YOU must generate

For every new application, generate these files:

### main.go
Entry point. HTTP server on port 8080. Must expose:
- `GET /` — the application UI or API response
- `GET /healthz` — returns `{"status":"ok"}` (used by Kubernetes probes)

### go.mod
```
module <app-name>
go 1.22
```

### Dockerfile
Use exactly this two-stage template — adapt only the `COPY` and `RUN` lines if the app has additional source files:

```dockerfile
FROM registry.access.redhat.com/ubi9/go-toolset:latest AS builder
WORKDIR /tmp/build
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 go build -buildvcs=false -o /tmp/app .

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
COPY --from=builder /tmp/app /usr/local/bin/app
USER 1001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/app"]
```

Key constraints:
- Build in `/tmp/build` (go-toolset runs as UID 1001, cannot write to `/app`)
- `-buildvcs=false` required (Tekton git-clone workspace lacks full git metadata)
- `USER 1001` in image; OpenShift overrides at runtime with a namespace UID

## Files already in the repository (do not regenerate)

```
deploy/base/          # Kustomize manifests — only update image: field
scripts/
  git-push.sh        # creates personal Git repo + pushes code
  build-image.sh     # Tekton Pipeline: git-clone + buildah
  gitops-deploy.sh   # spins up dev ArgoCD instance + deploys app
```

## Build verification

After generating all files, always run:
```bash
CGO_ENABLED=0 go build -buildvcs=false -o /dev/null .
```
Fix any compile errors before proceeding.

## Deploy workflow — call the Ansible playbooks

Once the build is verified, run these playbooks in order using your bash tool:

```bash
ansible-playbook scripts/git-push.yml
ansible-playbook scripts/build-image.yml      # takes 3-5 min — Tekton PipelineRun
ansible-playbook scripts/gitops-deploy.yml    # takes 2-3 min — ArgoCD startup
```

Each playbook prints named task output. Wait for it to succeed before running the next.
If a task fails, the error is shown inline — read it and fix the root cause.

## In-cluster LLM service
- Base URL : http://qwen36-predictor.llm-inference.svc.cluster.local:8080/v1
- Model ID  : qwen36
- API       : OpenAI-compatible
- Always add `"chat_template_kwargs": {"enable_thinking": false}` to every request body
EOF

# ── Kustomize: pipeline/base/ ─────────────────────────────────────────────────
info "Writing pipeline/base Kustomize manifests..."
mkdir -p pipeline/base

cat > pipeline/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pipeline.yaml
  - workspace-pvc.yaml
EOF

cat > pipeline/base/pipeline.yaml << 'EOF'
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build-app
spec:
  params:
    - name: git-url
      type: string
    - name: image
      type: string
  workspaces:
    - name: source
  tasks:
    - name: clone
      taskRef:
        resolver: cluster
        params:
          - name: kind
            value: task
          - name: name
            value: git-clone
          - name: namespace
            value: openshift-pipelines
      params:
        - name: URL
          value: $(params.git-url)
        - name: REVISION
          value: main
      workspaces:
        - name: output
          workspace: source
    - name: build
      runAfter: [clone]
      taskRef:
        resolver: cluster
        params:
          - name: kind
            value: task
          - name: name
            value: buildah
          - name: namespace
            value: openshift-pipelines
      params:
        - name: IMAGE
          value: $(params.image)
        - name: CONTEXT
          value: .
      workspaces:
        - name: source
          workspace: source
EOF

cat > pipeline/base/workspace-pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: build-ws
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

# ── Kustomize: gitops/base/ ───────────────────────────────────────────────────
info "Writing gitops/base Kustomize manifests..."
mkdir -p gitops/base

cat > gitops/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - argocd.yaml
EOF

cat > gitops/base/argocd.yaml << 'EOF'
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: argocd
spec:
  server:
    insecure: true
    route:
      enabled: true
      tls:
        termination: edge
  applicationSet:
    enabled: false
  notifications:
    enabled: false
EOF

# ── Ansible playbooks (scripts/) ──────────────────────────────────────────────
info "Writing Ansible deploy playbooks..."
mkdir -p scripts

cat > scripts/git-push.yml << 'EOF'
---
- name: Push code to personal Git server repository
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    app_name: "{{ lookup('env', 'APP_NAME') | default('fortune-cookie') }}"
    git_server: "{{ lookup('env', 'GIT_SERVER') }}"
    git_email: "{{ lookup('env', 'GIT_EMAIL') | default('dev@workshop.local') }}"
    git_name: "{{ lookup('env', 'GIT_NAME') | default('Developer') }}"

  tasks:
    - name: Remove existing origin remote
      command: git remote remove origin
      ignore_errors: true

    - name: Create repository on Git server
      command: gitpop init --host {{ git_server }} --name {{ app_name }}

    - name: Configure git identity
      shell: |
        git config user.email "{{ git_email }}"
        git config user.name  "{{ git_name }}"

    - name: Stage and commit all files
      shell: |
        git add -A
        git commit -m "feat: {{ app_name }} initial implementation" || true

    - name: Push to Git server
      command: git push -u origin main

    - name: Show repository URL
      command: git remote get-url origin
      register: repo_url

    - name: Print result
      debug:
        msg: "Repo: {{ repo_url.stdout }}"
EOF

cat > scripts/build-image.yml << 'EOF'
---
- name: Build container image with OpenShift Pipelines
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    app_name: "{{ lookup('env', 'APP_NAME') | default('fortune-cookie') }}"
    build_ns: "{{ app_name }}-build"
    image: "image-registry.openshift-image-registry.svc:5000/{{ app_name }}-build/{{ app_name }}:latest"

  tasks:
    - name: Get repository URL
      command: git remote get-url origin
      register: repo_url

    - name: Create build namespace
      command: oc new-project {{ build_ns }}
      ignore_errors: true

    - name: Grant pipeline service account registry-editor role
      command: >
        oc policy add-role-to-user registry-editor
        system:serviceaccount:{{ build_ns }}:pipeline
        -n {{ build_ns }}
      ignore_errors: true

    - name: Apply Tekton Pipeline and workspace PVC (Kustomize)
      command: oc apply -k pipeline/base -n {{ build_ns }}

    - name: Trigger PipelineRun
      shell: |
        oc create -n {{ build_ns }} -o jsonpath='{.metadata.name}' -f - <<YAML
        apiVersion: tekton.dev/v1
        kind: PipelineRun
        metadata:
          generateName: build-app-
        spec:
          serviceAccountName: pipeline
          pipelineRef:
            name: build-app
          params:
            - name: git-url
              value: {{ repo_url.stdout }}
            - name: image
              value: {{ image }}
          workspaces:
            - name: source
              persistentVolumeClaim:
                claimName: build-ws
        YAML
      register: pipeline_run

    - name: Wait for PipelineRun to succeed
      # 900s — cluster task resolver may fetch on first run
      command: >
        oc wait pipelinerun {{ pipeline_run.stdout }}
        -n {{ build_ns }}
        --for=condition=Succeeded
        --timeout=900s

    - name: Print built image reference
      debug:
        msg: "Image: {{ image }}"
EOF

cat > scripts/gitops-deploy.yml << 'EOF'
---
- name: Deploy application via developer-owned Argo CD
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    app_name: "{{ lookup('env', 'APP_NAME') | default('fortune-cookie') }}"
    dev_ns: "{{ app_name }}-dev"
    build_ns: "{{ app_name }}-build"
    image: "image-registry.openshift-image-registry.svc:5000/{{ app_name }}-build/{{ app_name }}:latest"

  tasks:
    - name: Get repository URL
      command: git remote get-url origin
      register: repo_url

    - name: Create dev namespace
      command: oc new-project {{ dev_ns }}
      ignore_errors: true

    - name: Allow dev namespace to pull from build namespace
      command: >
        oc policy add-role-to-user system:image-puller
        system:serviceaccount:{{ dev_ns }}:default
        -n {{ build_ns }}
      ignore_errors: true

    - name: Update image reference in deployment manifest
      replace:
        path: deploy/base/deployment.yaml
        regexp: 'image: .*'
        replace: "image: {{ image }}"

    - name: Commit and push updated manifest
      shell: |
        git add deploy/base/deployment.yaml
        git commit -m "ci: update image to {{ app_name }}:latest" || true
        git push

    - name: Deploy developer-owned Argo CD instance (Kustomize)
      command: oc apply -k gitops/base -n {{ dev_ns }}

    - name: Wait for ArgoCD CR to become Available
      shell: |
        for i in $(seq 1 30); do
          PHASE=$(oc get argocd argocd -n {{ dev_ns }} \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
          echo "  phase=${PHASE} (${i}/30)"
          [ "${PHASE}" = "Available" ] && exit 0
          sleep 10
        done
        exit 1

    - name: Wait for argocd-server deployment
      command: >
        oc wait deployment/argocd-server
        -n {{ dev_ns }}
        --for=condition=Available
        --timeout=120s

    - name: Create Argo CD Application
      shell: |
        oc apply -n {{ dev_ns }} -f - <<YAML
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: {{ app_name }}
        spec:
          project: default
          source:
            repoURL: {{ repo_url.stdout }}
            targetRevision: main
            path: deploy/base
          destination:
            server: https://kubernetes.default.svc
            namespace: {{ dev_ns }}
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
        YAML

    - name: Wait for application to sync and become healthy
      shell: |
        for i in $(seq 1 30); do
          SYNC=$(oc get application {{ app_name }} -n {{ dev_ns }} \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
          HEALTH=$(oc get application {{ app_name }} -n {{ dev_ns }} \
            -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
          echo "  sync=${SYNC} health=${HEALTH} (${i}/30)"
          [ "${SYNC}" = "Synced" ] && [ "${HEALTH}" = "Healthy" ] && exit 0
          sleep 10
        done

    - name: Show application and Argo CD URLs
      shell: |
        echo "App:    https://$(oc get route {{ app_name }} -n {{ dev_ns }} -o jsonpath='{.spec.host}')"
        echo "ArgoCD: https://$(oc get route argocd-server -n {{ dev_ns }} -o jsonpath='{.spec.host}')"
      register: urls

    - name: Print URLs
      debug:
        msg: "{{ urls.stdout_lines }}"
EOF

# ── opencode.json ─────────────────────────────────────────────────────────────
info "Writing opencode.json..."
cat > opencode.json << EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "qwen36": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Qwen3.6",
      "options": {
        "baseURL": "${LLM_URL}",
        "apiKey": "dummy",
        "chunkTimeout": 120000,
        "timeout": 600000
      },
      "models": {
        "qwen36": {
          "name": "${LLM_MODEL}",
          "reasoning": true,
          "tool_call": true,
          "interleaved": { "field": "reasoning_content" },
          "limit": { "context": 32768, "output": 8192 }
        }
      }
    }
  },
  "model": "qwen36/qwen36",
  "agent": {
    "plan": { "temperature": 0.1 },
    "build": { "temperature": 0.6 }
  },
  "autoupdate": false,
  "instructions": ["AGENTS.md"]
}
EOF

# ── devfile.yaml (reference only — not used in this e2e) ──────────────────────
cat > devfile.yaml << EOF
schemaVersion: 2.2.2
metadata:
  name: go-app-workspace
  description: Go development environment with OpenCode AI assistant
attributes:
  controller.devfile.io/storage-type: per-user
components:
  - name: dev
    container:
      image: quay.io/devfile/universal-developer-image:latest
      memoryRequest: 2Gi
      memoryLimit: 6Gi
      env:
        - name: GIT_SERVER
          value: "${GIT_SERVER}"
        - name: PATH
          value: /home/user/.opencode/bin:/home/user/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
commands:
  - id: bootstrap
    exec:
      component: dev
      label: "Install tools (OpenCode + gitpop + Ansible)"
      commandLine: |
        set -e
        curl -fsSL https://opencode.ai/install | bash
        mkdir -p \${HOME}/.local/bin
        curl -fsSL "\${GIT_SERVER}/dl/gitpop?os=linux&arch=amd64" \\
          -o \${HOME}/.local/bin/gitpop
        chmod +x \${HOME}/.local/bin/gitpop
        pip install --quiet ansible
        echo "Bootstrap complete."
      workingDir: \${PROJECT_SOURCE}
  - id: git-push
    exec:
      component: dev
      label: "1. Push code to Git server"
      commandLine: ansible-playbook scripts/git-push.yml
      workingDir: \${PROJECT_SOURCE}
  - id: build-image
    exec:
      component: dev
      label: "2. Build container image"
      commandLine: ansible-playbook scripts/build-image.yml
      workingDir: \${PROJECT_SOURCE}
  - id: gitops-deploy
    exec:
      component: dev
      label: "3. Deploy with Argo CD"
      commandLine: ansible-playbook scripts/gitops-deploy.yml
      workingDir: \${PROJECT_SOURCE}
events:
  postStart:
    - bootstrap
EOF

# No pre-committed Dockerfile — AGENTS.md contains the exact template.
# The LLM generates it from those instructions (one less reason to say "don't modify").
info "Dockerfile will be generated by OpenCode from AGENTS.md instructions"

# ── Kustomize manifests (deploy/base/) ───────────────────────────────────────
# Including placeholder manifests removes another source of LLM non-determinism.
# The LLM only needs to write main.go and go.mod; deploy/ is always present.
info "Writing deploy/base manifests..."
mkdir -p deploy/base

cat > deploy/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - route.yaml
EOF

cat > deploy/base/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fortune-cookie
  labels:
    app.kubernetes.io/name: fortune-cookie
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: fortune-cookie
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fortune-cookie
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: fortune-cookie
          image: PLACEHOLDER
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 3
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
EOF

cat > deploy/base/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: fortune-cookie
spec:
  selector:
    app.kubernetes.io/name: fortune-cookie
  ports:
    - port: 8080
      targetPort: 8080
EOF

cat > deploy/base/route.yaml << 'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: fortune-cookie
spec:
  to:
    kind: Service
    name: fortune-cookie
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# ── Commit & push to Git server ───────────────────────────────────────────────
git add .
git commit -m "feat: Go app template with OpenCode + Qwen3.6 conventions"

info "Creating template repo on Git server: $TEMPLATE_REPO_NAME"
"$GITPOP_BIN" init --host "$GIT_SERVER" --name "$TEMPLATE_REPO_NAME"

git push -u origin main --force
TEMPLATE_URL=$(git remote get-url origin)
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
