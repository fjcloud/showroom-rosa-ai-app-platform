# E2E Workshop Validation

End-to-end script that validates the full workshop flow from a single terminal — no DevSpaces UI required.

## What it does

| Phase | Actor | What happens |
|-------|-------|-------------|
| **Phase 1** | Platform Engineer | Creates `go-app-template` repo on the Git server with `AGENTS.md`, `devfile.yaml`, `opencode.json` — exactly what the PE does in Lab 5 |
| **Phase 2** | Developer simulation | Deploys a UDI container in the cluster, installs OpenCode + gitpop, clones the template, sends two OpenCode prompts (build + deploy) |
| **Phase 3** | Validation | Checks generated files, Git repos, image build, Argo CD sync, live route, and LLM API |

## Prerequisites

- `oc` logged in with cluster-admin
- Qwen3.6 `InferenceService` Ready in `llm-inference` namespace
- Argo CD `workshop` AppProject created (done in Lab 2)
- OpenShift Pipelines running

## Usage

```bash
# Run with defaults
export GIT_SERVER=https://gitpop.apps.sno.msl.cloud
bash e2e/run.sh

# Override app name or namespace
APP_NAME=my-test-app E2E_NS=my-e2e bash e2e/run.sh

# Clean up all created resources
bash e2e/cleanup.sh
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GIT_SERVER` | `https://gitpop.apps.sno.msl.cloud` | Git server base URL |
| `APP_NAME` | `fortune-cookie` | Name of the generated app |
| `E2E_NS` | `workshop-e2e` | Namespace for the developer simulation pod |

## What gets created

- Git repos: `go-app-template`, `fortune-cookie` on the Git server
- Namespaces: `workshop-e2e`, `fortune-cookie-build`, `fortune-cookie-dev`
- BuildConfig + ImageStream in `fortune-cookie-build`
- Argo CD Application `fortune-cookie` in `openshift-gitops`
- Deployment + Route in `fortune-cookie-dev`

## Interpreting results

The script exits 0 if all checks pass, 1 if any fail.
Each check prints `✅` (pass) or `⚠️ FAIL` (fail) with a label.

OpenCode build and deploy logs are saved in the pod at:
- `/tmp/opencode-build.log`
- `/tmp/opencode-deploy.log`

To inspect them after a run:
```bash
oc exec e2e-developer -n workshop-e2e -- cat /tmp/opencode-build.log
oc exec e2e-developer -n workshop-e2e -- cat /tmp/opencode-deploy.log
```
