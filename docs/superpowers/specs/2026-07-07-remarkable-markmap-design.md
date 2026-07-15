# reMarkable diary — `kind:markmap` (markdown outlines as ink)

**Date:** 2026-07-07
**Status:** Design approved

## Goal

Render **markmaps** (markdown-outline mind maps, markmap.js style — root on the left,
headings/bullets nesting rightward, text on branch lines, no boxes) as native ink on the
reMarkable takeover diary. Write "mind map / map out / outline X" on the page → gpt-5.5
returns a markdown outline → the diary draws a left→right tidy tree.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Look | **Markmap** — left→right tidy tree, text on branches, no boxes |
| Input | **Markdown outline** (`#` headings + nested `-` bullets) in the render-spec |
| Scope | **Plain diary path only** (the diary's own LLM answer). No agent-desk/@k8s markmaps yet. |
| Raw outline | **Always through the model** — no direct-render bypass for a handwritten outline |
| Interactivity | Static ink only — no collapsible/animated nodes |

## Context

`diary.c` already has `render_flow` (diary.c:273): a mermaid-style node+edge graph with
layered top-down auto-layout, auto-sized boxes, bbox→scale→center fit-to-region, connector
drawing, and edge labels. It reuses `draw_glyph`, `text_w`, `normalize_text`, the e-ink
`upd()` refresh, and a hand-drawn bowed-rectangle helper. `render_markmap` is a sibling of
`render_flow` and reuses the same helpers and fit math. The LLM answer path is
`ask_model` → `SYS_PROMPT` → JSON `{kind:text|flow|draw}`; markmap adds a fourth kind.

## Render-spec

```json
{ "kind":"markmap",
  "md":"# K8s\n## Workloads\n- Pods\n- Deployments\n## Networking\n- Services\n- Ingress" }
```

Only `md` (a markdown outline string) is carried; all layout happens on-device.

## Components (isolated units, all in `diary.c` beside `render_flow`)

1. **Outline parser** — `md` → array of `(depth, text)`, then a tree.
   - Heading `#×k` → depth `k-1` (`#`=0, `##`=1, `###`=2…).
   - Bullet (`-`/`*`/`+`) → depth = (nearest preceding heading depth + 1) + indent level,
     where indent level = leading spaces / 2 (a tab = one level).
   - Lines with no marker are ignored in v1.
   - Build the tree with a depth stack: for a node of depth `d`, pop while `top.depth ≥ d`,
     attach to the new top as parent, push. The first `#` is the root; any stray depth-0
     nodes hang off a synthetic virtual root.
2. **Tidy left→right layout** — `x = depth × COLGAP`. Assign `y` by in-order leaf walk:
   each leaf takes the next `y` slot (`leafIndex × ROWGAP`); each internal node's `y` is the
   midpoint of its children's `y` span. (Reingold–Tilford first pass.)
3. **Fit + draw** — reuse `render_flow`'s bbox→scale→center math (regX/regY/regW/regH → `s`,
   `offx/offy`) so any tree fits the page. Per node: draw the **label as text on the branch**
   (normalized, truncated with `…`), a small node dot, and a smooth **bowed connector** from
   the parent's right edge to the child's left edge (reuse the hand-drawn bow style). Root is
   drawn larger/heavier. Depth maps to font weight/size, not color (e-ink is grayscale).
4. **Dispatch** — add `"markmap"` to the `spec.kind` switch: parse `md` → layout → draw.

## Prompt change

Add one clause to `SYS_PROMPT`: if the user asks to "map out", "mind map", "markmap",
"outline", or "brainstorm" a topic, return
`{"kind":"markmap","md":"# Topic\n## Branch\n- leaf"}` — a markdown outline, 3–4 levels
deep, short labels. `text` / `flow` / `draw` behavior is unchanged.

## Limits & error handling

- Cap ~48 nodes; truncate long labels with `…`.
- Empty or unparseable `md` → fall back to `kind:text` with the raw answer.
- Deep/wide trees stay on the page via scale-to-fit; if a label would render below a
  legibility floor, cap depth/nodes rather than shrink further.

## Testing

- Off-device: extend the existing PNG-dump path (used to tune the table/stats drawers) to
  render a canned `kind:markmap` outline to a PNG; iterate the parser + geometry there.
- On-device: build (toltec docker `./build.sh`), deploy over Wi-Fi (`./deploy.sh
  172.16.10.175 id_diary`), write "mind map of X" and confirm the drawn tree.

## Out of scope (YAGNI)

- agent-desk / `@k8s` markmaps (render-spec schema + coercer) — later.
- Direct render of a handwritten outline without the model.
- Collapsible / animated / interactive nodes.
- Color-coded branches (limited on e-ink).
