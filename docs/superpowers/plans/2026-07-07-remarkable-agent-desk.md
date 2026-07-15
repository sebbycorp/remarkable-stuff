# reMarkable → kagent (FortiGate & F5) via agent-desk — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the reMarkable takeover diary answer `@forti`/`@f5` questions by calling the FortiGate and F5 BIG-IP kagent agents over A2A through a thin cluster router (`agent-desk`), and render the result on the tablet as a **table** or **stats** tiles (JSON/text fallback).

**Architecture:** Tablet stays thin. After OCR, `diary.c` detects an `@forti`/`@f5` prefix and POSTs the text to `agent-desk` (a NodePort on the gateway node, reached exactly like the existing LLM NodePorts). `agent-desk` (Python) parses the prefix + format keyword, calls the matching kagent agent via A2A, coerces the agent's output into a strict **render-spec** JSON with a schema-constrained gpt-5.5 pass through agentgateway, and returns it. `diary.c` draws the render-spec.

**Tech Stack:** C (armv7 cross-compiled via toltec, cJSON, stb) on the tablet; Python 3.11 + httpx + FastAPI on the cluster; kagent A2A (JSON-RPC 2.0); agentgateway; Kubernetes (context `maniak-goose`) + ArgoCD (`sebbycorp/k8s-goose`).

**Repo layout note:** source lives in `github.com/sebbycorp/k8s-goose`: the tablet app in `remarkable-diary/takeover/`, and this new service in `remarkable-diary/agent-desk/`. Clone it locally in Task 1. The design spec is `docs/superpowers/specs/2026-07-07-remarkable-agent-desk-design.md`.

**The render-spec contract (shared between router and tablet):**

```json
{ "kind":"table", "title":"Wi-Fi devices (7)", "columns":["Name","IP","Type","SSID"],
  "rows":[["iPad","172.16.10.31","tablet","Home"]], "note":"source: FortiGate 7.4" }
{ "kind":"stats", "title":"app1 pool", "tiles":[{"label":"Members up","value":"3/4"}], "note":"..." }
{ "kind":"json",  "title":"...", "text":"<pretty JSON string>" }
{ "kind":"text",  "title":"...", "text":"plain answer or error message" }
```

---

## Phase A — cluster `agent-desk` router

### Task 1: Working tree + discover the kagent A2A surface

**Files:**
- Create: `remarkable-diary/agent-desk/` (new dir in a local clone of `sebbycorp/k8s-goose`)
- Create: `remarkable-diary/agent-desk/DISCOVERY.md`

- [ ] **Step 1: Clone the repo and create the service dir**

```bash
cd ~/src 2>/dev/null || mkdir -p ~/src && cd ~/src
[ -d k8s-goose ] || gh repo clone sebbycorp/k8s-goose
cd k8s-goose && git checkout -b feat/agent-desk
mkdir -p remarkable-diary/agent-desk
```

- [ ] **Step 2: Confirm the cluster context and find the kagent agents**

```bash
kubectl config use-context maniak-goose
kubectl get agents.kagent.dev -A            # list kagent Agent CRs
kubectl get svc -n kagent                    # A2A service(s)
```

Expected: the FortiGate and F5 BIG-IP `Agent` resources appear. Note their names + namespace.

- [ ] **Step 3: Fetch each agent's A2A card from an in-cluster pod**

kagent serves A2A per-agent. Confirm the URL shape and the agent card:

```bash
kubectl run a2a-probe -n kagent --rm -it --image=curlimages/curl --restart=Never -- \
  sh -c 'for a in <forti-agent> <f5-agent>; do
    echo "== $a =="; curl -s http://kagent.kagent.svc.cluster.local:8083/api/a2a/kagent/$a/.well-known/agent.json; echo; done'
```

Expected: JSON agent cards. **Record in `DISCOVERY.md`:** the exact base URL template, whether it exposes `message/send` + `tasks/get`, whether streaming is required, and the artifact shape of a completed task. If the path differs from the guess above, the real one from the card's `url` field wins.

- [ ] **Step 4: Do one real A2A round-trip by hand and save the response**

```bash
kubectl run a2a-probe -n kagent --rm -it --image=curlimages/curl --restart=Never -- \
  sh -c 'curl -s -X POST http://kagent.kagent.svc.cluster.local:8083/api/a2a/kagent/<forti-agent> \
   -H "Content-Type: application/json" \
   -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"messageId\":\"m1\",\"parts\":[{\"kind\":\"text\",\"text\":\"list wifi clients\"}]}}}"' \
  | tee /dev/stderr
```

Expected: a JSON-RPC result containing a Task (with `status.state` and `artifacts[]`) or a Message. **Paste the real response into `DISCOVERY.md`** — Task 4's parsing is written against it.

- [ ] **Step 5: Commit the discovery notes**

```bash
git add remarkable-diary/agent-desk/DISCOVERY.md
git commit -m "docs(agent-desk): record kagent A2A surface for forti + f5"
```

---

### Task 2: Prefix + format parser

**Files:**
- Create: `remarkable-diary/agent-desk/parse.py`
- Test: `remarkable-diary/agent-desk/test_parse.py`

- [ ] **Step 1: Write the failing test**

```python
# test_parse.py
from parse import parse_ask, ParsedAsk

def test_forti_table_prefix():
    assert parse_ask("@forti table: what devices are on my wifi") == ParsedAsk(
        agent="forti", fmt="table", query="what devices are on my wifi")

def test_f5_stats_prefix():
    assert parse_ask("@f5 stats: app1 pool health") == ParsedAsk(
        agent="f5", fmt="stats", query="app1 pool health")

def test_default_format_per_agent():
    assert parse_ask("@forti what's connected").fmt == "table"   # forti default
    assert parse_ask("@f5 pool app1").fmt == "stats"             # f5 default

def test_json_and_text_keywords():
    assert parse_ask("@f5 json: node states").fmt == "json"
    assert parse_ask("@forti text: summarize the network").fmt == "text"

def test_no_prefix_returns_none():
    assert parse_ask("just a normal diary question") is None

def test_case_and_whitespace_insensitive():
    p = parse_ask("  @FORTI   TABLE:   clients  ")
    assert p.agent == "forti" and p.fmt == "table" and p.query == "clients"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd remarkable-diary/agent-desk && python -m pytest test_parse.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'parse'` / `ImportError`.

- [ ] **Step 3: Implement `parse.py`**

```python
# parse.py — turn "@forti table: ..." into a routed, formatted ask.
from dataclasses import dataclass
import re

AGENTS = {"forti": "table", "f5": "stats"}   # name -> default format
FORMATS = {"table", "stats", "json", "text"}
_PREFIX = re.compile(r"^\s*@(forti|f5)\b\s*", re.IGNORECASE)
_FORMAT = re.compile(r"^(table|stats|json|text)\s*:\s*", re.IGNORECASE)

@dataclass(eq=True)
class ParsedAsk:
    agent: str
    fmt: str
    query: str

def parse_ask(text: str):
    """Return a ParsedAsk if text targets an agent, else None."""
    if not text:
        return None
    m = _PREFIX.match(text)
    if not m:
        return None
    agent = m.group(1).lower()
    rest = text[m.end():]
    fmt = AGENTS[agent]
    fm = _FORMAT.match(rest)
    if fm:
        fmt = fm.group(1).lower()
        rest = rest[fm.end():]
    return ParsedAsk(agent=agent, fmt=fmt, query=rest.strip())
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `python -m pytest test_parse.py -v`
Expected: 6 passed.

- [ ] **Step 5: Commit**

```bash
git add remarkable-diary/agent-desk/parse.py remarkable-diary/agent-desk/test_parse.py
git commit -m "feat(agent-desk): prefix + format parser for @forti/@f5"
```

---

### Task 3: render-spec builder + coercion prompt

**Files:**
- Create: `remarkable-diary/agent-desk/renderspec.py`
- Test: `remarkable-diary/agent-desk/test_renderspec.py`

The router never trusts the agent to emit our schema. It asks gpt-5.5 (through agentgateway) to convert the agent's free text/JSON into a render-spec, constrained by `response_format` json_schema. `renderspec.py` owns: the JSON schema, the coercion prompt, and safe fallbacks that never raise.

- [ ] **Step 1: Write the failing test (pure functions only — no network)**

```python
# test_renderspec.py
import json
from renderspec import SCHEMA, coercion_messages, safe_spec, error_spec

def test_schema_has_four_kinds():
    kinds = SCHEMA["schema"]["properties"]["kind"]["enum"]
    assert set(kinds) == {"table", "stats", "json", "text"}

def test_coercion_messages_embed_query_and_format_and_payload():
    msgs = coercion_messages("table", "wifi clients", "raw agent output here")
    blob = json.dumps(msgs)
    assert "table" in blob and "wifi clients" in blob and "raw agent output here" in blob
    assert msgs[0]["role"] == "system" and msgs[-1]["role"] == "user"

def test_safe_spec_passes_valid_table_through():
    good = {"kind": "table", "title": "t", "columns": ["A"], "rows": [["1"]]}
    assert safe_spec(good, "table") == good

def test_safe_spec_wraps_garbage_as_text():
    out = safe_spec({"unexpected": True}, "table")
    assert out["kind"] == "text" and out["text"]

def test_safe_spec_coerces_missing_rows_to_empty():
    out = safe_spec({"kind": "table", "title": "t", "columns": ["A"]}, "table")
    assert out["kind"] == "table" and out["rows"] == []

def test_error_spec_is_text_kind():
    e = error_spec("forti", "timeout")
    assert e["kind"] == "text" and "forti" in e["text"].lower() and "timeout" in e["text"]
```

- [ ] **Step 2: Run and watch it fail**

Run: `python -m pytest test_renderspec.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'renderspec'`.

- [ ] **Step 3: Implement `renderspec.py`**

```python
# renderspec.py — the render-spec schema, the coercion prompt, and safe fallbacks.

SCHEMA = {
    "name": "render_spec",
    "strict": True,
    "schema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["kind", "title", "columns", "rows", "tiles", "text", "note"],
        "properties": {
            "kind": {"type": "string", "enum": ["table", "stats", "json", "text"]},
            "title": {"type": "string"},
            "columns": {"type": "array", "items": {"type": "string"}},
            "rows": {"type": "array", "items": {"type": "array", "items": {"type": "string"}}},
            "tiles": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "required": ["label", "value"],
                "properties": {"label": {"type": "string"}, "value": {"type": "string"}}}},
            "text": {"type": "string"},
            "note": {"type": "string"},
        },
    },
}

_SYS = (
    "You convert an infrastructure agent's answer into a compact render-spec for a "
    "small e-ink tablet. Return ONLY an object matching the schema. Rules:\n"
    "- kind=table: fill columns + rows (rows are arrays of short strings, same length as columns). "
    "Keep to <=6 columns and <=15 rows; abbreviate long values.\n"
    "- kind=stats: fill tiles (label + short value), <=8 tiles. Good for health/counters.\n"
    "- kind=json: put a compact pretty-printed JSON string in text.\n"
    "- kind=text: put a short prose answer in text (<=6 lines).\n"
    "Always set title (<=40 chars) and note (data source, <=40 chars). "
    "Leave unused fields as empty arrays/strings."
)

def coercion_messages(fmt: str, query: str, agent_payload: str):
    user = (
        f"Preferred format: {fmt}. If the data does not fit that format, pick the best of "
        f"table/stats/json/text.\nUser question: {query}\n\nAgent output:\n{agent_payload}"
    )
    return [{"role": "system", "content": _SYS}, {"role": "user", "content": user}]

_EMPTY = {"kind": "text", "title": "", "columns": [], "rows": [], "tiles": [], "text": "", "note": ""}

def _base():
    return dict(_EMPTY)

def safe_spec(obj, fmt: str):
    """Never raise. Return a valid render-spec, degrading to text on anything odd."""
    if not isinstance(obj, dict):
        s = _base(); s["text"] = str(obj); return s
    kind = obj.get("kind")
    if kind not in ("table", "stats", "json", "text"):
        s = _base(); s["text"] = obj.get("text") or str(obj); s["title"] = str(obj.get("title", "")); return s
    s = _base()
    s["kind"] = kind
    s["title"] = str(obj.get("title", ""))
    s["note"] = str(obj.get("note", ""))
    if kind == "table":
        s["columns"] = [str(c) for c in (obj.get("columns") or [])]
        s["rows"] = [[str(c) for c in row] for row in (obj.get("rows") or []) if isinstance(row, list)]
    elif kind == "stats":
        s["tiles"] = [{"label": str(t.get("label", "")), "value": str(t.get("value", ""))}
                      for t in (obj.get("tiles") or []) if isinstance(t, dict)]
    else:  # json | text
        s["text"] = str(obj.get("text", ""))
    return s

def error_spec(agent: str, msg: str):
    s = _base()
    s["title"] = f"{agent} agent"
    s["text"] = f"The {agent} agent {msg}."
    return s
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `python -m pytest test_renderspec.py -v`
Expected: 6 passed.

- [ ] **Step 5: Commit**

```bash
git add remarkable-diary/agent-desk/renderspec.py remarkable-diary/agent-desk/test_renderspec.py
git commit -m "feat(agent-desk): render-spec schema, coercion prompt, safe fallbacks"
```

---

### Task 4: A2A client

**Files:**
- Create: `remarkable-diary/agent-desk/a2a.py`
- Test: `remarkable-diary/agent-desk/test_a2a.py`

> Adjust field paths in `_extract_text` to match the real response captured in `DISCOVERY.md` (Task 1 Step 4) before trusting it live. The parsing below targets standard A2A: a JSON-RPC `result` that is a Task with `artifacts[].parts[].text`, or a Message with `parts[].text`.

- [ ] **Step 1: Write the failing test (parsing + request-body shape, no live network)**

```python
# test_a2a.py
import json
from a2a import build_send_body, extract_text, is_terminal

def test_build_send_body_is_valid_jsonrpc():
    b = json.loads(build_send_body("list wifi clients", msg_id="m1", rpc_id="1"))
    assert b["jsonrpc"] == "2.0" and b["method"] == "message/send"
    assert b["params"]["message"]["parts"][0]["text"] == "list wifi clients"

def test_extract_text_from_task_artifacts():
    result = {"kind": "task", "status": {"state": "completed"},
              "artifacts": [{"parts": [{"kind": "text", "text": "3 clients: iPad, TV, phone"}]}]}
    assert extract_text(result) == "3 clients: iPad, TV, phone"

def test_extract_text_from_message():
    result = {"kind": "message", "parts": [{"kind": "text", "text": "hello"}]}
    assert extract_text(result) == "hello"

def test_is_terminal_states():
    assert is_terminal({"status": {"state": "completed"}})
    assert is_terminal({"status": {"state": "failed"}})
    assert not is_terminal({"status": {"state": "working"}})
```

- [ ] **Step 2: Run and watch it fail**

Run: `python -m pytest test_a2a.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'a2a'`.

- [ ] **Step 3: Implement `a2a.py`**

```python
# a2a.py — minimal A2A (JSON-RPC 2.0) client for kagent agents.
import json
import httpx

TERMINAL = {"completed", "failed", "canceled", "rejected"}

def build_send_body(text: str, msg_id: str, rpc_id: str) -> str:
    return json.dumps({
        "jsonrpc": "2.0", "id": rpc_id, "method": "message/send",
        "params": {"message": {"role": "user", "messageId": msg_id,
                                "parts": [{"kind": "text", "text": text}]}},
    })

def build_get_body(task_id: str, rpc_id: str) -> str:
    return json.dumps({"jsonrpc": "2.0", "id": rpc_id, "method": "tasks/get",
                       "params": {"id": task_id}})

def is_terminal(result: dict) -> bool:
    return (result.get("status") or {}).get("state") in TERMINAL

def extract_text(result: dict) -> str:
    """Pull human text out of a Task or Message result. Tolerant of shape."""
    parts = []
    for art in result.get("artifacts") or []:
        for p in art.get("parts") or []:
            if p.get("text"):
                parts.append(p["text"])
    if not parts:  # a plain Message result
        for p in result.get("parts") or []:
            if p.get("text"):
                parts.append(p["text"])
    if not parts and result.get("status", {}).get("message"):
        for p in result["status"]["message"].get("parts") or []:
            if p.get("text"):
                parts.append(p["text"])
    return "\n".join(parts).strip()

async def call_agent(base_url: str, text: str, *, timeout: float = 25.0,
                     poll_every: float = 1.5) -> str:
    """Send a message, poll to completion if needed, return the agent's text.
    Raises TimeoutError / RuntimeError on failure (caller maps to error_spec)."""
    import asyncio
    async with httpx.AsyncClient(timeout=timeout) as c:
        r = await c.post(base_url, content=build_send_body(text, "m1", "1"),
                         headers={"Content-Type": "application/json"})
        r.raise_for_status()
        result = r.json().get("result") or {}
        if result.get("kind") == "message" or (not result.get("status")):
            return extract_text(result)
        task_id = result.get("id")
        deadline = asyncio.get_event_loop().time() + timeout
        while not is_terminal(result):
            if asyncio.get_event_loop().time() > deadline:
                raise TimeoutError("did not answer in time")
            await asyncio.sleep(poll_every)
            g = await c.post(base_url, content=build_get_body(task_id, "2"),
                             headers={"Content-Type": "application/json"})
            g.raise_for_status()
            result = g.json().get("result") or {}
        if (result.get("status") or {}).get("state") != "completed":
            raise RuntimeError("returned an error")
        return extract_text(result)
```

- [ ] **Step 4: Run the unit tests and confirm they pass**

Run: `python -m pytest test_a2a.py -v`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add remarkable-diary/agent-desk/a2a.py remarkable-diary/agent-desk/test_a2a.py
git commit -m "feat(agent-desk): minimal A2A client (message/send + poll)"
```

---

### Task 5: HTTP server tying it together

**Files:**
- Create: `remarkable-diary/agent-desk/server.py`
- Create: `remarkable-diary/agent-desk/llm.py`
- Test: `remarkable-diary/agent-desk/test_server.py`

- [ ] **Step 1: Write `llm.py` (the schema-constrained coercion call)**

```python
# llm.py — call gpt-5.5 through agentgateway with a strict json_schema response.
import os, json, httpx
from renderspec import SCHEMA, coercion_messages, safe_spec

GW_URL = os.environ.get("GW_URL",
    "http://agentgateway-proxy.agentgateway-system.svc.cluster.local/openai/v1/chat/completions")
MODEL = os.environ.get("MODEL", "gpt-5.5")

async def coerce_to_spec(fmt: str, query: str, agent_payload: str) -> dict:
    body = {"model": MODEL, "messages": coercion_messages(fmt, query, agent_payload),
            "response_format": {"type": "json_schema", "json_schema": SCHEMA}}
    async with httpx.AsyncClient(timeout=30.0) as c:
        r = await c.post(GW_URL, json=body)
        r.raise_for_status()
        content = r.json()["choices"][0]["message"]["content"]
    try:
        return safe_spec(json.loads(content), fmt)
    except Exception:
        return safe_spec(content, fmt)
```

- [ ] **Step 2: Write the failing server test (parser wiring + error path, LLM/A2A monkeypatched)**

```python
# test_server.py
import asyncio, json
from fastapi.testclient import TestClient
import server

def test_unprefixed_returns_422(monkeypatch):
    c = TestClient(server.app)
    r = c.post("/ask", json={"text": "just a normal question"})
    assert r.status_code == 422

def test_forti_table_happy_path(monkeypatch):
    async def fake_call(url, text, **kw): return "iPad 172.16.10.31 tablet Home"
    async def fake_coerce(fmt, query, payload):
        return {"kind": "table", "title": "Wi-Fi", "columns": ["Name"], "rows": [["iPad"]],
                "tiles": [], "text": "", "note": "FortiGate"}
    monkeypatch.setattr(server, "call_agent", fake_call)
    monkeypatch.setattr(server, "coerce_to_spec", fake_coerce)
    c = TestClient(server.app)
    r = c.post("/ask", json={"text": "@forti table: what's on wifi"})
    assert r.status_code == 200 and r.json()["kind"] == "table"

def test_agent_timeout_returns_text_error(monkeypatch):
    async def boom(url, text, **kw): raise TimeoutError("did not answer in time")
    monkeypatch.setattr(server, "call_agent", boom)
    c = TestClient(server.app)
    r = c.post("/ask", json={"text": "@f5 stats: pool app1"})
    body = r.json()
    assert r.status_code == 200 and body["kind"] == "text" and "f5" in body["text"].lower()
```

- [ ] **Step 3: Run and watch it fail**

Run: `python -m pytest test_server.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'server'`.

- [ ] **Step 4: Implement `server.py`**

```python
# server.py — POST /ask {text} -> render-spec. Thin: parse, A2A, coerce, fallback.
import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from parse import parse_ask
from a2a import call_agent
from llm import coerce_to_spec
from renderspec import error_spec

# Per-agent A2A base URLs (VERIFIED in DISCOVERY.md — per-agent service root, JSONRPC);
# overridable via env.
A2A_URLS = {
    "forti": os.environ.get("FORTI_A2A_URL",
        "http://fortigate-agent.kagent.svc.cluster.local:8080/"),
    "f5": os.environ.get("F5_A2A_URL",
        "http://f5-bigip-agent.kagent.svc.cluster.local:8080/"),
}

app = FastAPI(title="agent-desk")

class Ask(BaseModel):
    text: str

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.post("/ask")
async def ask(body: Ask):
    parsed = parse_ask(body.text)
    if not parsed:
        raise HTTPException(status_code=422, detail="no @forti/@f5 prefix")
    try:
        payload = await call_agent(A2A_URLS[parsed.agent], parsed.query)
    except TimeoutError:
        return error_spec(parsed.agent, "didn't answer in time")
    except Exception:
        return error_spec(parsed.agent, "returned an error")
    if not payload:
        return error_spec(parsed.agent, "returned nothing")
    try:
        return await coerce_to_spec(parsed.fmt, parsed.query, payload)
    except Exception:
        from renderspec import safe_spec
        return safe_spec(payload, parsed.fmt)
```

- [ ] **Step 5: Add `requirements.txt` and run all tests**

Create `remarkable-diary/agent-desk/requirements.txt`:

```
fastapi==0.115.0
uvicorn==0.30.6
httpx==0.27.2
pydantic==2.9.2
```

Run: `pip install -r requirements.txt pytest && python -m pytest -v`
Expected: all tests across the four test files pass.

- [ ] **Step 6: Commit**

```bash
git add remarkable-diary/agent-desk/server.py remarkable-diary/agent-desk/llm.py \
        remarkable-diary/agent-desk/test_server.py remarkable-diary/agent-desk/requirements.txt
git commit -m "feat(agent-desk): FastAPI /ask endpoint wiring parser+A2A+coercion"
```

---

### Task 6: Package + deploy agent-desk (ConfigMap image, NodePort, ArgoCD)

**Files:**
- Create: `remarkable-diary/agent-desk/deploy.yaml`
- Create: `remarkable-diary/agent-desk/configmap.yaml`
- Create: `remarkable-diary/agent-desk/argocd-app.yaml`

Mirror the existing `remarkable-diary` self-installing pattern (stock `python:3.11-slim`, code from a ConfigMap) so no image build/push is needed.

- [ ] **Step 1: Generate the code ConfigMap**

```bash
cd remarkable-diary/agent-desk
kubectl create configmap agent-desk-code -n remarkable-diary \
  --from-file=server.py --from-file=parse.py --from-file=a2a.py \
  --from-file=renderspec.py --from-file=llm.py \
  --dry-run=client -o yaml > configmap.yaml
```

- [ ] **Step 2: Write `deploy.yaml` (Deployment + Service NodePort)**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-desk
  namespace: remarkable-diary
  labels: {app: agent-desk}
spec:
  replicas: 1
  selector: {matchLabels: {app: agent-desk}}
  template:
    metadata: {labels: {app: agent-desk}}
    spec:
      containers:
        - name: agent-desk
          image: python:3.11-slim
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -e
              pip install --no-cache-dir -q -r /cfg/requirements.txt
              cd /cfg && exec uvicorn server:app --host 0.0.0.0 --port 8000
          env:
            - {name: GW_URL,  value: "http://agentgateway-proxy.agentgateway-system.svc.cluster.local/openai/v1/chat/completions"}
            - {name: MODEL,   value: "gpt-5.5"}
            - {name: FORTI_A2A_URL, value: "http://fortigate-agent.kagent.svc.cluster.local:8080/"}
            - {name: F5_A2A_URL,    value: "http://f5-bigip-agent.kagent.svc.cluster.local:8080/"}
          ports: [{containerPort: 8000}]
          volumeMounts: [{name: code, mountPath: /cfg}]
          readinessProbe: {httpGet: {path: /healthz, port: 8000}, initialDelaySeconds: 20}
          resources:
            requests: {cpu: "50m", memory: "192Mi"}
            limits:   {cpu: "1",   memory: "512Mi"}
      volumes:
        - name: code
          configMap: {name: agent-desk-code}
---
apiVersion: v1
kind: Service
metadata:
  name: agent-desk
  namespace: remarkable-diary
spec:
  type: NodePort
  selector: {app: agent-desk}
  ports:
    - {port: 8000, targetPort: 8000, nodePort: 30260}   # tablet -> 172.16.10.155:30260/ask
```

Also append `requirements.txt` into the ConfigMap so `/cfg/requirements.txt` exists:

```bash
kubectl create configmap agent-desk-code -n remarkable-diary \
  --from-file=server.py --from-file=parse.py --from-file=a2a.py \
  --from-file=renderspec.py --from-file=llm.py --from-file=requirements.txt \
  --dry-run=client -o yaml > configmap.yaml
```

- [ ] **Step 3: Write `argocd-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: agent-desk
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/sebbycorp/k8s-goose.git
    targetRevision: main
    path: remarkable-diary/agent-desk
    directory:
      recurse: false
      include: "{configmap.yaml,deploy.yaml}"
  destination: {server: https://kubernetes.default.svc, namespace: remarkable-diary}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true]
```

- [ ] **Step 4: Apply directly first and verify from inside the cluster**

```bash
kubectl apply -f configmap.yaml -f deploy.yaml
kubectl rollout status deploy/agent-desk -n remarkable-diary
kubectl run desk-probe -n remarkable-diary --rm -it --image=curlimages/curl --restart=Never -- \
  sh -c 'curl -s -X POST http://agent-desk:8000/ask -H "Content-Type: application/json" \
    -d "{\"text\":\"@forti table: what devices are on my wifi\"}"'
```

Expected: a render-spec JSON with `"kind":"table"` and real rows from the FortiGate agent. If it errors, check `kubectl logs deploy/agent-desk -n remarkable-diary` and fix the A2A URL from `DISCOVERY.md`.

- [ ] **Step 5: Verify the NodePort is reachable from the gateway node IP**

```bash
kubectl run desk-probe -n remarkable-diary --rm -it --image=curlimages/curl --restart=Never -- \
  sh -c 'curl -s -X POST http://172.16.10.155:30260/ask -H "Content-Type: application/json" \
    -d "{\"text\":\"@f5 stats: app1 pool health\"}"'
```

Expected: a `"kind":"stats"` render-spec. This is exactly the URL the tablet will hit.

- [ ] **Step 6: Commit + push (ArgoCD picks it up)**

```bash
git add remarkable-diary/agent-desk/deploy.yaml remarkable-diary/agent-desk/configmap.yaml \
        remarkable-diary/agent-desk/argocd-app.yaml
git commit -m "feat(agent-desk): deploy manifests + NodePort 30260 + argocd app"
git push -u origin feat/agent-desk
kubectl apply -f argocd-app.yaml
```

---

## Phase B — tablet rendering (`diary.c`)

All edits are in `remarkable-diary/takeover/diary.c`. Line numbers below refer to the current file. Build with the existing `./build.sh`; deploy with `./deploy.sh <host> <key>`. Verify C rendering off-agent using a **canned render-spec** debug mode (Task 7) so drawing geometry can be tuned without a live agent.

### Task 7: agent-desk POST helper + prefix hook + canned-spec debug mode

**Files:**
- Modify: `remarkable-diary/takeover/diary.c`

- [ ] **Step 1: Add the agent-desk endpoint constants near the other GW defines (after line 32)**

```c
#define DESK_PORT 30260
#define DESK_PATH "/ask"
```

- [ ] **Step 2: Add a POST helper that returns the raw JSON body (not OpenAI-wrapped)**

Insert after `ask_model` (after line 108). `http_post` returns headers+body; strip to the body:

```c
// POST {text} to agent-desk; return the raw render-spec JSON body (caller frees).
static char* http_body(char* resp){
  if(!resp)return NULL;
  char* b=strstr(resp,"\r\n\r\n"); if(!b)return resp; b+=4;
  char* out=strdup(b); return out;
}
static char* ask_agent_desk(const char* text){
  char* q=jesc(text); int cap=strlen(q)+64; char* body=malloc(cap);
  int n=snprintf(body,cap,"{\"text\":\"%s\"}",q); free(q);
  char* resp=http_post(DESK_PORT,DESK_PATH,body,n); free(body);
  if(!resp)return NULL;
  char* jb=http_body(resp); free(resp); return jb;   // raw render-spec JSON
}
```

- [ ] **Step 3: Add prefix detection helper (after the block above)**

```c
static int is_agent_prefix(const char* s){
  while(*s==' '||*s=='\t')s++;
  return (s[0]=='@') && (!strncasecmp(s+1,"forti",5) || !strncasecmp(s+1,"f5",2));
}
```

- [ ] **Step 4: Hook the main loop — route prefixed questions to agent-desk (edit lines 336–338)**

Replace:

```c
      char* ans=ask_model(cur_model,qtext); free(qtext);          // selected model answers the text
      if(!ans){fprintf(stderr,"[diary] no answer\n");continue;}
```

with:

```c
      int to_agent = is_agent_prefix(qtext);
      char* ans = to_agent ? ask_agent_desk(qtext) : ask_model(cur_model,qtext);
      free(qtext);
      if(!ans){fprintf(stderr,"[diary] no answer\n");continue;}
```

`ans` is now either an OpenAI answer (LLM path, `flow`/`draw`/`text`) or a render-spec (agent path, `table`/`stats`/`json`/`text`). The JSON dispatch at lines 341–358 already parses `kind`; Tasks 8–10 add the new kinds there.

- [ ] **Step 5: Add a canned-spec debug mode in `main` (right after `draw_model_bar();` at line 294)**

Lets you render a render-spec from a file without any agent, to tune geometry:

```c
  if(getenv("DESK_DEMO")){
    FILE* df=fopen(getenv("DESK_DEMO"),"rb");
    if(df){fseek(df,0,SEEK_END);long dl=ftell(df);fseek(df,0,SEEK_SET);
      char* buf=malloc(dl+1);fread(buf,1,dl,df);buf[dl]=0;fclose(df);
      extern void render_spec(const char* json,int startY);   // defined in Task 10
      render_spec(buf,MODEL_BAR_H+40); free(buf);
      fprintf(stderr,"[diary] demo rendered; sleeping\n"); pause(); }
  }
```

- [ ] **Step 6: Build to confirm it still compiles (render_spec is a forward extern until Task 10)**

For now, stub `render_spec` at file scope so it links; Task 10 replaces the stub:

```c
void render_spec(const char* json,int startY){(void)json;(void)startY;}
```

Run: `cd remarkable-diary/takeover && ./build.sh`
Expected: `built: diary, ink (armv7)` with no errors.

- [ ] **Step 7: Commit**

```bash
git add remarkable-diary/takeover/diary.c
git commit -m "feat(diary): route @forti/@f5 to agent-desk + canned-spec demo mode"
```

---

### Task 8: metric font + font switching (tables/stats need a non-cursive face)

**Files:**
- Modify: `remarkable-diary/takeover/diary.c`
- Modify: `remarkable-diary/takeover/diary-start.sh`

- [ ] **Step 1: Add a second font face and an active-font pointer (after line 69)**

```c
static stbtt_fontinfo mono; static unsigned char* monobuf; static int have_mono=0;
static stbtt_fontinfo* AF=&font;   // active font used by draw_glyph/text_w
#define MONO_PATH "/home/root/diary-mono.ttf"
```

- [ ] **Step 2: Point `draw_glyph` and `text_w` at the active font**

Change every `&font` inside `draw_glyph` (line 112) and `text_w` (line 113) to `AF`. Concretely, in `draw_glyph` replace the three `&font` uses (`stbtt_GetCodepointHMetrics`, `stbtt_GetCodepointBitmapBox`, `stbtt_MakeCodepointBitmap`) with `AF`, and in `text_w` replace `&font` in `stbtt_GetCodepointHMetrics` with `AF`.

- [ ] **Step 3: Load the mono font in `main` (after `font_load()` success, line 290)**

```c
  { FILE* mf=fopen(MONO_PATH,"rb"); if(mf){fseek(mf,0,SEEK_END);long sz=ftell(mf);fseek(mf,0,SEEK_SET);
      monobuf=malloc(sz);fread(monobuf,1,sz,mf);fclose(mf); have_mono=stbtt_InitFont(&mono,monobuf,0);} }
```

- [ ] **Step 4: Ship the font in the start script**

In `diary-start.sh`, before launching the diary, fetch a metric TTF once if missing:

```sh
[ -f /home/root/diary-mono.ttf ] || cp /usr/share/fonts/ttf/DejaVuSansMono.ttf /home/root/diary-mono.ttf 2>/dev/null || true
```

If DejaVu isn't on-device, `deploy.sh` should `scp` a bundled `DejaVuSansMono.ttf` to `/home/root/diary-mono.ttf`. Add to `deploy.sh` after the `diary` scp:

```sh
[ -f DejaVuSansMono.ttf ] && $SCP DejaVuSansMono.ttf "root@$HOST:/home/root/diary-mono.ttf" || true
```

- [ ] **Step 5: Build to confirm it compiles**

Run: `./build.sh`
Expected: builds clean. (`AF` defaults to the cursive font, so existing rendering is unchanged.)

- [ ] **Step 6: Commit**

```bash
git add remarkable-diary/takeover/diary.c remarkable-diary/takeover/diary-start.sh remarkable-diary/takeover/deploy.sh
git commit -m "feat(diary): add metric font face + active-font switch for tabular output"
```

---

### Task 9: `render_table`

**Files:**
- Modify: `remarkable-diary/takeover/diary.c`

- [ ] **Step 1: Add `render_table` after `render_flow` (after line 283)**

```c
// Draw a bordered table from cJSON columns[] + rows[][]. Metric font, scale-to-fit width.
static void render_table(cJSON* title,cJSON* cols,cJSON* rows,cJSON* note,int startY){
  AF = have_mono ? &mono : &font;
  float sc=stbtt_ScaleForPixelHeight(AF,40); int asc; stbtt_GetFontVMetrics(AF,&asc,0,0); int fasc=(int)(asc*sc);
  int ncol=cJSON_GetArraySize(cols); if(ncol<=0){AF=&font;return;} if(ncol>6)ncol=6;
  int x0=60, y=startY, tblW=vinfo.xres-120, rowH=64, pad=14;
  // title
  if(cJSON_IsString(title)&&title->valuestring[0]){char t[128];snprintf(t,sizeof t,"%s",title->valuestring);normalize_text(t);
    float ts=stbtt_ScaleForPixelHeight(AF,48);int ta=(int)(asc*ts);int tx=x0;for(char* c=t;*c;c++)tx+=draw_glyph((unsigned char)*c,tx,y+ta,ts);y+=ta+24;}
  // measure column widths from header + cells (cap total to tblW)
  int cw[6]; for(int i=0;i<ncol;i++){cJSON* h=cJSON_GetArrayItem(cols,i);int w=h&&cJSON_IsString(h)?text_w(h->valuestring,strlen(h->valuestring),sc):40;cw[i]=w;}
  int nrow=cJSON_GetArraySize(rows); if(nrow>15)nrow=15;
  for(int r=0;r<nrow;r++){cJSON* row=cJSON_GetArrayItem(rows,r);for(int i=0;i<ncol;i++){cJSON* cell=cJSON_GetArrayItem(row,i);if(cell&&cJSON_IsString(cell)){int w=text_w(cell->valuestring,strlen(cell->valuestring),sc);if(w>cw[i])cw[i]=w;}}}
  int sum=0; for(int i=0;i<ncol;i++){cw[i]+=2*pad; sum+=cw[i];}
  if(sum>tblW){double k=(double)tblW/sum; for(int i=0;i<ncol;i++)cw[i]=(int)(cw[i]*k); sum=tblW;}
  // header row (filled divider under it)
  int hx=x0; int headY=y;
  for(int i=0;i<ncol;i++){cJSON* h=cJSON_GetArrayItem(cols,i);char s[64];snprintf(s,sizeof s,"%s",h&&cJSON_IsString(h)?h->valuestring:"");normalize_text(s);
    int tx=hx+pad;for(char* c=s;*c && tx<hx+cw[i]-pad;c++)tx+=draw_glyph((unsigned char)*c,tx,y+fasc,sc);hx+=cw[i];}
  y+=rowH; lineT(x0,y-8,x0+sum,y-8,2,0);
  // data rows + grid
  for(int r=0;r<nrow;r++){cJSON* row=cJSON_GetArrayItem(rows,r);int rx=x0;
    for(int i=0;i<ncol;i++){cJSON* cell=cJSON_GetArrayItem(row,i);char s[96];snprintf(s,sizeof s,"%s",cell&&cJSON_IsString(cell)?cell->valuestring:"");normalize_text(s);
      int tx=rx+pad;for(char* c=s;*c && tx<rx+cw[i]-pad;c++)tx+=draw_glyph((unsigned char)*c,tx,y+fasc,sc);rx+=cw[i];}
    y+=rowH; lineT(x0,y-8,x0+sum,y-8,1,gray565(160));
    if(y>(int)vinfo.yres-90)break;}
  // vertical rules + outer box
  int gx=x0; rectT(x0,headY-8,sum,y-headY,1,gray565(160));
  for(int i=0;i<ncol-1;i++){gx+=cw[i];lineT(gx,headY-8,gx,y-8,1,gray565(160));}
  // note
  if(cJSON_IsString(note)&&note->valuestring[0]){float ns=stbtt_ScaleForPixelHeight(AF,30);int na=(int)(asc*ns);char nt[80];snprintf(nt,sizeof nt,"%s",note->valuestring);normalize_text(nt);int nx=x0;for(char* c=nt;*c;c++)nx+=draw_glyph((unsigned char)*c,nx,y+18+na,ns);}
  upd(0,startY-10,vinfo.xres,(y-startY)+80,2,0);
  AF=&font;
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `./build.sh`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add remarkable-diary/takeover/diary.c
git commit -m "feat(diary): render_table (bordered grid, metric font, scale-to-fit)"
```

---

### Task 10: `render_stats` + `render_spec` dispatch (replaces the Task 7 stub)

**Files:**
- Modify: `remarkable-diary/takeover/diary.c`

- [ ] **Step 1: Add `render_stats` after `render_table`**

```c
// Draw KPI tiles (2 columns): big value + small label, boxed.
static void render_stats(cJSON* title,cJSON* tiles,cJSON* note,int startY){
  AF = have_mono ? &mono : &font;
  int asc; stbtt_GetFontVMetrics(AF,&asc,0,0);
  int x0=60,y=startY,areaW=vinfo.xres-120;
  if(cJSON_IsString(title)&&title->valuestring[0]){char t[128];snprintf(t,sizeof t,"%s",title->valuestring);normalize_text(t);
    float ts=stbtt_ScaleForPixelHeight(AF,48);int ta=(int)(asc*ts);int tx=x0;for(char* c=t;*c;c++)tx+=draw_glyph((unsigned char)*c,tx,y+ta,ts);y+=ta+28;}
  int n=cJSON_GetArraySize(tiles); if(n>8)n=8; int ncol=2, gap=30;
  int tileW=(areaW-gap)/ncol, tileH=150;
  float vs=stbtt_ScaleForPixelHeight(AF,70), ls=stbtt_ScaleForPixelHeight(AF,34);
  int vasc=(int)(asc*vs), lasc=(int)(asc*ls);
  for(int i=0;i<n;i++){cJSON* t=cJSON_GetArrayItem(tiles,i);
    cJSON* lb=cJSON_GetObjectItem(t,"label"),*vv=cJSON_GetObjectItem(t,"value");
    int col=i%ncol,rowi=i/ncol; int tx=x0+col*(tileW+gap), ty=y+rowi*(tileH+gap);
    rough_rect(tx,ty,tileW,tileH,2,0);
    char v[48];snprintf(v,sizeof v,"%s",vv&&cJSON_IsString(vv)?vv->valuestring:"");normalize_text(v);
    int vw=text_w(v,strlen(v),vs),vx=tx+(tileW-vw)/2;for(char* c=v;*c;c++)vx+=draw_glyph((unsigned char)*c,vx,ty+28+vasc,vs);
    char l[64];snprintf(l,sizeof l,"%s",lb&&cJSON_IsString(lb)?lb->valuestring:"");normalize_text(l);
    int lw=text_w(l,strlen(l),ls),lx=tx+(tileW-lw)/2;for(char* c=l;*c;c++)lx+=draw_glyph((unsigned char)*c,lx,ty+tileH-24,ls);
  }
  int rows=(n+ncol-1)/ncol; int endY=y+rows*(tileH+gap);
  if(cJSON_IsString(note)&&note->valuestring[0]){float ns=stbtt_ScaleForPixelHeight(AF,30);int na=(int)(asc*ns);char nt[80];snprintf(nt,sizeof nt,"%s",note->valuestring);normalize_text(nt);int nx=x0;for(char* c=nt;*c;c++)nx+=draw_glyph((unsigned char)*c,nx,endY+na,ns);endY+=na+10;}
  upd(0,startY-10,vinfo.xres,(endY-startY)+40,2,0);
  AF=&font;
}
```

- [ ] **Step 2: Replace the Task 7 stub with the real `render_spec`**

Delete `void render_spec(const char* json,int startY){(void)json;(void)startY;}` and add after `render_stats`:

```c
// Parse a render-spec JSON and draw it. Clears the page below the model bar first.
void render_spec(const char* json,int startY){
  cJSON* root=cJSON_Parse(json);
  if(!root){render_text_block(json,startY);return;}
  cJSON* kind=cJSON_GetObjectItem(root,"kind");
  const char* k=cJSON_IsString(kind)?kind->valuestring:"text";
  cJSON* title=cJSON_GetObjectItem(root,"title");
  cJSON* note=cJSON_GetObjectItem(root,"note");
  // clear the writing area for table/stats (they own the page)
  if(!strcmp(k,"table")||!strcmp(k,"stats")){
    for(int q=0;q<stride*(int)vinfo.yres;q++)fb[q]=0xFFFF;upd(0,0,vinfo.xres,vinfo.yres,1,1);draw_model_bar();startY=MODEL_BAR_H+40;}
  if(!strcmp(k,"table")){
    render_table(title,cJSON_GetObjectItem(root,"columns"),cJSON_GetObjectItem(root,"rows"),note,startY);
  }else if(!strcmp(k,"stats")){
    render_stats(title,cJSON_GetObjectItem(root,"tiles"),note,startY);
  }else{ // json | text
    cJSON* tv=cJSON_GetObjectItem(root,"text");
    render_text_block(cJSON_IsString(tv)?tv->valuestring:json,startY);
  }
  cJSON_Delete(root);
}
```

- [ ] **Step 3: Route the agent-path answer through `render_spec` in the main loop**

In the dispatch block (lines 341–358), the agent path should bypass the LLM `flow`/`draw` branches. Guard the existing dispatch with `to_agent`:

Replace the start of the parse block (line 341) — change:

```c
      // try parse JSON (strip to first {..last })
      char* jstart=strchr(ans,'{'); char* jend=strrchr(ans,'}');
```

to:

```c
      if(to_agent){ render_spec(ans,by1+70); free(ans);
        bx0=1e9;by0=1e9;bx1=-1;by1=-1;lx=ly=-1; fprintf(stderr,"[diary] agent done\n"); continue; }
      // try parse JSON (strip to first {..last })
      char* jstart=strchr(ans,'{'); char* jend=strrchr(ans,'}');
```

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: builds clean.

- [ ] **Step 5: Verify rendering with canned specs (no agent needed)**

Create two fixtures and view them on the tablet via the demo mode from Task 7 Step 5:

```bash
cat > /tmp/table.json <<'JSON'
{"kind":"table","title":"Wi-Fi devices (4)","columns":["Name","IP","Type","SSID"],
 "rows":[["iPad","172.16.10.31","tablet","Home"],["Apple TV","172.16.10.42","mediaplayer","Home"],
 ["Pixel 8","172.16.10.55","phone","Home"],["Roku","172.16.10.61","mediaplayer","IoT"]],
 "note":"source: FortiGate 7.4"}
JSON
cat > /tmp/stats.json <<'JSON'
{"kind":"stats","title":"app1 pool","tiles":[{"label":"Members up","value":"3/4"},
 {"label":"Cur conns","value":"128"},{"label":"Bits/sec","value":"4.2M"},{"label":"VIP","value":"UP"}],
 "note":"source: BIG-IP iControl"}
JSON
./deploy.sh <host> <key>        # pushes the binary + fonts
ssh root@<host> 'sh /home/root/diary-stop.sh; ' 
scp /tmp/table.json root@<host>:/home/root/demo.json
ssh root@<host> 'systemctl stop xochitl; setsid /opt/bin/rm2fb_server & sleep 2; DESK_DEMO=/home/root/demo.json LD_PRELOAD=/opt/lib/librm2fb_client.so /home/root/diary'
```

Expected: a clean bordered table fills the page. Repeat with `stats.json` → four KPI tiles. Tune `rowH`/`tileH`/font sizes if cramped, rebuild, recheck. Then `sh /home/root/diary-start.sh` to return to normal.

- [ ] **Step 6: Commit**

```bash
git add remarkable-diary/takeover/diary.c
git commit -m "feat(diary): render_stats + render_spec dispatch (table/stats/json/text)"
```

---

### Task 11: End-to-end on the tablet

**Files:** none (verification).

- [ ] **Step 1: Deploy the current binary and start the diary normally**

```bash
cd remarkable-diary/takeover && ./deploy.sh <host> <key>
```

Expected: `deployed to <host> and restarted.` Diary boots (model bar visible).

- [ ] **Step 2: Confirm agent-desk is reachable from the tablet's network**

```bash
ssh root@<host> 'curl -s -X POST http://172.16.10.155:30260/ask -H "Content-Type: application/json" -d "{\"text\":\"@forti table: what devices are on my wifi\"}"'
```

Expected: a `"kind":"table"` render-spec JSON printed on the tablet's shell. (Confirms the tablet→NodePort hop before testing the pen path.)

- [ ] **Step 3: Example 1 — FortiGate table (live handwriting)**

Write on the page: `@forti table: what devices are on my wifi`. Pause ~3s.
Expected: page clears, a bordered device table draws with real clients; footer shows the FortiGate source.

- [ ] **Step 4: Example 2 — F5 BIG-IP stats (live handwriting)**

On a fresh page (rubber-tap to clear): `@f5 stats: app1 pool health`. Pause ~3s.
Expected: four KPI tiles (members up / conns / throughput / VIP state).

- [ ] **Step 5: Regression — a normal (unprefixed) question still uses the LLM path**

Write: `what's the capital of France?`
Expected: cursive prose answer as before (LLM path untouched).

- [ ] **Step 6: Error path — agent unreachable degrades gracefully**

Scale agent-desk to 0 (`kubectl scale deploy/agent-desk -n remarkable-diary --replicas=0`), write `@f5 stats: pool app1`.
Expected: a short text answer like "The f5 agent returned an error." — no crash, no stuck panel. Scale back to 1 afterward.

- [ ] **Step 7: Commit the final state / open PR**

```bash
git push
gh pr create --repo sebbycorp/k8s-goose --title "reMarkable @forti/@f5 agent-desk" \
  --body "reMarkable takeover diary can call FortiGate + F5 kagent agents over A2A via a thin agent-desk router and render table/stats on the tablet. See docs/superpowers/specs/2026-07-07-remarkable-agent-desk-design.md."
```

---

## Self-review notes

- **Spec coverage:** thin tablet + cluster router (Tasks 5–6), A2A to kagent (Tasks 1,4), `@forti`/`@f5` prefix + format keyword (Task 2), render-spec contract (Task 3), FortiGate→table (Task 9 + 11.3), F5→stats (Task 10 + 11.4), json/text fallback (Task 10), metric font (Task 8), agentgateway coercion (Task 5 `llm.py`), error handling (Task 3 `error_spec`, Task 5, Task 11.6), off-agent C testing via canned specs (Tasks 7,10). All spec sections map to a task.
- **Deferred/verify items** from the spec are front-loaded into Task 1 (real A2A URL + response shape) and Task 6.5 (NodePort reachability), rather than assumed.
- **Type consistency:** `ParsedAsk(agent,fmt,query)`, `render_spec(json,startY)`, `render_table/render_stats`, `AF` active-font pointer, `ask_agent_desk`, `is_agent_prefix` are used consistently across tasks.
- **Out of scope (unchanged from spec):** Python injection-diary port, on-screen agent selector, LLM intent routing, write-back actions, animated table reveal.
