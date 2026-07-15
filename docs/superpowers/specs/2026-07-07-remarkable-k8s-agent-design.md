# reMarkable → kagent k8s-agent (KubeAssist) via agent-desk (`@k8s`)

**Date:** 2026-07-07
**Status:** Design approved ("Do it")

## Goal

Add a third agent-desk backend so writing `@k8s ...` on the reMarkable takeover diary
routes to a real kagent **k8s-agent (KubeAssist)** in the `k8s-goose` cluster and renders
the answer as a table / stats / text page — mirroring the shipped `@forti` / `@f5` flow.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Scope of tools | **Full KubeAssist** — all read + write tools (Create/Delete/Patch/Scale/Exec/Apply) |
| MCP install | kagent's **official tools server** (`ghcr.io/kagent-dev/kagent/tools:0.2.1`, `--tools=k8s`) |
| Delivery | **GitOps** — files in `config/kagent-models/`, synced by ArgoCD `kagent-models` app (`sebbycorp/k8s-goose`) |
| Front-end scope | **Full end-to-end** — cluster agent + `@k8s` routing in agent-desk + diary.c |
| Default render format | **auto** (coercer picks table for lists, text for diagnoses) |

Cluster baseline (context `maniak-goose`): kagent-**enterprise** controller `0.4.8`; agents
`demo/drone/f5-bigip/fortigate/github` present; **no** k8s-agent and **no** built-in tools
server (installed minimal). So both the tools server and the agent are net-new.

## Part A — Cluster (GitOps, `config/kagent-models/`)

1. **`kagent-tools-server.yaml`** — rendered from the OSS `kagent-tools` chart (v0.2.1):
   - `ServiceAccount` `kagent-tools`
   - `Deployment` `kagent-tools` — `/tool-server --port 8084 --metrics-port 8085 --tools=k8s`,
     image `ghcr.io/kagent-dev/kagent/tools:0.2.1`, in-cluster SA auth (`TOKEN_PASSTHROUGH=false`)
   - `Service` `kagent-tools` :8084 (+ `kagent-tools-metrics` :8085)
   - `RemoteMCPServer` `kagent-tool-server` → `http://kagent-tools.kagent:8084/mcp`
2. **`kagent-tools-rbac.yaml`** — `ClusterRole` `kagent-tools-cluster-admin-role`
   (`*/*` verbs `*` — Full KubeAssist) + `ClusterRoleBinding` to the SA.
   *This one file is the blast radius; swap to the chart's `rbac.readOnly=true` rules to
   restrict to read-only later.*
3. **`k8s-agent.yaml`** — `Agent` (`kagent.dev/v1alpha2`, ns `kagent`), model `gpt-5-5`,
   KubeAssist system prompt (from the official kagent chart, using the in-cluster
   `kagent-builtin-prompts` ConfigMap promptTemplate), `a2aConfig` skills
   (cluster-diagnostics / resource-management / security-audit), and `tools:` referencing
   `kagent-tool-server` with the full `k8s_*` tool set (18 base + `k8s_scale`,
   `k8s_rollout`, `k8s_generate_resource`).

**Verify gate (PASSED 2026-07-07):** `k8s-agent` READY/ACCEPTED; RemoteMCPServer
discovered 22 tools; A2A `message/send` to `http://k8s-agent.kagent.svc:8080/` answered a
read ("list pods in kagent" → used `k8s_get_resources`) and a write ("label demo-agent
remarkable-test=hello" → applied, confirmed by kubectl, then reverted). Router `/ask`:
`@k8s table:` → table (12-row pod grid); `@k8s` auto → stats health tiles.

Deploy realities learned:
- `runtime: go` fails on this enterprise controller (golang-adk image digest not found) —
  used `runtime: python` like every other agent here.
- Worker node runs ~99% CPU requests; tools req trimmed to 25m, agent to 50m, and stale
  ReplicaSets/pods deleted to unstick scheduling. agent-desk rolling update also deadlocks
  on CPU surge — delete the old pod to let the new one schedule.
- The `kagent-tools-cluster-admin-role` ClusterRole already existed in the enterprise
  install; our file matched it (apply reported "configured").

## Part B — Tablet (`@k8s` routing)

4. **agent-desk router** — add `k8s` to the prefix parser + A2A agent map
   (`@k8s` → `k8s-agent.kagent.svc:8080`). Render-spec coercer unchanged; `@k8s`
   default format = auto (no fixed default unlike forti=table/f5=stats).
5. **diary.c** — OCR-normalize `@ k8s` / `@kubernetes` / `@k 8 s` → `@k8s`; add `k8s`
   to the detected-prefix set. Reuse existing table/stats/text drawers (no new C drawer).
   **BLOCKED:** the agent-desk-enabled diary.c (with `@forti`/`@f5` routing) was on the
   unpushed `feat/agent-desk` branch — it is NOT in the repo. The two edits needed, once
   that source is in hand:
   - OCR-normalize prompt: also map handwritten `@k8s` / `@kubernetes` / `@k 8 s` → `@k8s`
     (alongside the existing `@forti`/`@f5` normalization).
   - prefix allowlist: add `k8s` next to `forti`/`f5` so the line POSTs to agent-desk `/ask`.
   Nothing else on-device changes — the router returns the same render-spec kinds the
   existing table/stats/text drawers already handle.

## Data flow

```
tablet "@k8s table: pods in kagent not ready"
  → OCR (gpt-5.5) → normalize → @k8s detected
  → POST /ask agent-desk (NodePort 30260)
      → A2A → k8s-agent → kagent-tool-server MCP → cluster
      → gpt-5.5 coerce → render-spec {kind:table|stats|text}
  → diary draws page
```

## Error handling
- A2A timeout / empty → `kind:text` short message (same as forti/f5).
- Unknown/absent prefix → existing LLM path, untouched.
- Coerce failure → wrap raw agent output as `kind:text`.

## Out of scope (YAGNI)
- No on-device approval prompt (Full KubeAssist is fire-and-forget by choice).
- No new C drawer; no injection-diary (Python) port — flagship takeover only.
- Not re-enabling the enterprise helm tools subchart — standalone Deployment stays in the
  `config/kagent-models/` GitOps flow.
