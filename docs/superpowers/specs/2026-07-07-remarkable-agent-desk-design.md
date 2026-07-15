# reMarkable → kagent (FortiGate & F5 BIG-IP) via agent-desk

**Date:** 2026-07-07
**Status:** Design approved, pending spec review

## Goal

From the reMarkable takeover diary, write a prefixed question aimed at a real
infrastructure agent (FortiGate or F5 BIG-IP), have a cluster service invoke that
kagent agent over A2A, and render the result back on the tablet as a **table**,
**stats** tiles, or **JSON** — not just prose.

Two shipped examples:

1. **FortiGate → table** — `@forti table: what devices are on my wifi`
2. **F5 BIG-IP → stats** — `@f5 stats: app1 pool health`

This extends the working takeover diary (`diary.c` + rm2fb, OCR via gpt-5.5 through
agentgateway). It does **not** replace the plain LLM path — unprefixed questions
behave exactly as today.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Backends | kagent agents for FortiGate and F5 already exist in-cluster |
| Front-end | Takeover C app (flagship, on-device animated diary) |
| Invocation | A2A protocol to the kagent agents |
| Orchestration location | New thin cluster service (**agent-desk**); tablet stays thin |
| Routing | Keyword prefix on the page: `@forti` / `@f5` |
| F5 agent meaning | F5 BIG-IP (LTM): virtual servers, pools, node/conn stats |
| Format selection | Second keyword (`table:` / `stats:` / `json:` / `text:`), with per-agent default |

## Architecture & data flow

```
 reMarkable (takeover diary.c)
   You write:  @forti table: what's on my wifi
   pen idle → gpt-5.5 OCR (vision) → plain text
   prefix @forti/@f5 detected?
     no  → existing LLM path (unchanged)
     yes → POST {text} to agent-desk
   render-spec JSON returns → draw table / stats / json / text
        │ plain HTTP, NodePort (same style as the LLM calls)
        ▼
 cluster: agent-desk (new service)
   POST /ask {text}
     1. parse prefix (@forti|@f5) + format (table|stats|json|text) + strip → clean query
     2. A2A → matching kagent agent, await result
     3. coerce agent output → strict render-spec JSON (schema-constrained gpt-5.5 via agentgateway)
     4. return render-spec
        │ A2A (via agentgateway, traced)
        ├───────────────► FortiGate kagent agent
        └───────────────► F5 BIG-IP (LTM) kagent agent
```

**Rationale:** the tablet's only new responsibility is "POST text, draw the returned
spec." All A2A/JSON-RPC, timeouts, retries, and formatting live in Python where they
are easy to iterate. agentgateway fronts both the tablet→router hop (a NodePort, like
the existing LLM NodePorts) and the router→kagent A2A hop (tracing, rate-limit).
Rejected alternative: a hand-rolled A2A/JSON-RPC client inside `diary.c` — too heavy
to build and iterate on in C.

## Components (isolated units)

1. **agent-desk router** (cluster, new). Sub-parts, each independently testable:
   - *prefix/format parser* — `@forti table: ...` → `{agent:"forti", format:"table", query:"..."}`.
   - *A2A client* — discover agent card (`/.well-known/agent.json`), `message/send`
     (JSON-RPC 2.0), poll `tasks/get` to completion, extract artifact(s).
   - *render-spec formatter* — coerce agent output → one of the 4 render-spec shapes
     via a schema-constrained gpt-5.5 pass through agentgateway; guaranteed valid JSON.
   - *HTTP server* — `POST /ask`, fronted by an agentgateway NodePort.
2. **render-spec schema** — the shared contract between router and tablet (below).
3. **tablet `diary.c`** — after OCR, detect `@forti`/`@f5`; POST to agent-desk instead
   of the LLM; dispatch drawing on `spec.kind`.
4. **tablet `ink.c`** — new `table` drawer and `stats`-tile drawer; `json`/`text`
   reuse the existing text path. Bundle a sans/mono TTF for tabular data (cursive
   Dancing Script stays for prose).
5. **kagent agents** (FortiGate, F5 BIG-IP) — already deployed; the router only calls
   them. Verify their A2A endpoints and that they return the fields these examples need.

## The render-spec contract

The router **always** returns exactly one of these. All layout is pre-computed
server-side so `diary.c` only draws.

```json
{ "kind":"table", "title":"Wi-Fi devices (7)",
  "columns":["Name","IP","Type","SSID"],
  "rows":[["iPad","172.16.10.31","tablet","Home"]],
  "note":"source: FortiGate 7.4" }

{ "kind":"stats", "title":"app1 pool",
  "tiles":[{"label":"Members up","value":"3/4"},
           {"label":"Cur conns","value":"128"}],
  "note":"source: BIG-IP iControl" }

{ "kind":"json", "title":"...", "text":"<pretty JSON string>" }

{ "kind":"text", "title":"...", "text":"plain answer or error message" }
```

## The two examples

### Example 1 — FortiGate, table

- **Write:** `@forti table: what devices are on my wifi`
- Router strips to `what devices are on my wifi`, format `table`, agent `forti`.
- A2A → FortiGate kagent (fortigate-firewall REST recipes: `monitor/user/device`,
  DHCP leases, SSID associations).
- Coerce → `kind:table`, columns `[Name, IP, Type, SSID]`.
- Tablet draws a bordered grid.
- Default format for `@forti` when no keyword: **table**.

### Example 2 — F5 BIG-IP, stats

- **Write:** `@f5 stats: app1 pool health`
- A2A → F5 kagent (iControl REST: `/mgmt/tm/ltm/pool`, `/virtual`, node `/stats`).
- Coerce → `kind:stats`, tiles `[Members up, Cur conns, Bits/sec, VIP state]`.
- Tablet draws KPI tiles (2-column boxes: big value + small label).
- Default format for `@f5` when no keyword: **stats**.

`json:` on either agent dumps raw output; `text:` forces prose.

## On-device rendering

Add to `ink.c` / `diary.c`:

- **table drawer** — header row + grid lines; column widths from longest cell,
  scale-to-fit page width; truncate with `…` if needed.
- **stats-tile drawer** — 2-column boxes, large value (metric font) + small label.
- **json/text** — reuse existing text path; use the mono/sans font for `json`.
- Bundle a metric TTF (sans or mono) alongside `/home/root/diary-font.ttf`; select
  font per `kind` (cursive for `text` prose, metric for `table`/`stats`/`json`).
- Dispatch on `spec.kind` after the POST returns.

## Error handling

- Agent timeout / A2A error / empty result → `kind:text` with a short message
  (e.g. "FortiGate agent didn't answer in 20s").
- Unknown/absent prefix → existing LLM path, untouched.
- Format keyword that doesn't fit the data (e.g. `table:` on a scalar) → router
  falls back to the best format for the data.
- Render-spec formatter always yields valid JSON; if the schema pass fails, wrap the
  raw agent output as `kind:text`.

## Testing

- **Router** — testable off-tablet: `curl POST /ask` from an in-cluster pod with each
  prefix/format combo; assert the render-spec shape against the live kagent agents.
- **C renderers** — iterate against canned render-spec JSON (debug flag / local file);
  no live agent needed to tune drawing geometry.
- **End-to-end** — write each example on the tablet, confirm the table / stats page.

## To verify during implementation

- Exact kagent A2A surface: agent card location, `message/send` vs `tasks/send`,
  streaming vs poll, artifact structure.
- That the FortiGate and F5 kagent agents actually expose the fields these examples
  need (device inventory; pool/member/conn stats).
- agentgateway route/NodePort for the tablet→agent-desk hop, and whether the
  router→kagent A2A hop routes through agentgateway or hits kagent directly.

## Out of scope (YAGNI)

- Porting agent-routing into the cluster injection diary (Python) — flagship only.
- On-screen agent selector / LLM intent routing — keyword prefix only.
- Write-back actions to FortiGate/F5 — read-only queries only.
- Streaming/animated table reveal — draw the spec once.
