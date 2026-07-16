# Live writing stream — tablet → desktop (Windows + Mac)

**Date:** 2026-07-16  
**Status:** Design + MVP scaffold  
**Device:** reMarkable 2 (SebbyCorp Notepad / `diary.c`)  
**Clients:** Windows desktop + Mac (same app, cross-platform)

---

## Goal

While writing on the tablet, see ink appear **live** on a desktop app (presentations, meetings, dual-screen drafting). Same experience on Windows and Mac.

---

## What already exists (ecosystem)

| Approach | Works with our takeover? | Notes |
|----------|--------------------------|--------|
| Official reMarkable Screen Share / Live View | ❌ | Needs stock xochitl + rM cloud/desktop app |
| rMview / reStream (community) | ❌ while diary owns panel | They read xochitl / stock pipelines; our `diary` + rm2fb replaces that |
| **Custom stream from diary** | ✅ | We own strokes + framebuffer — best path |

So we build our own lightweight stream, not bolt onto the official app.

---

## Options (trade-offs)

### A — Framebuffer snapshots (video-like)
- Periodically encode content band PNG/JPEG → push over network  
- **Pros:** trivial correctness (what you see is what you get, including AI answers/bitmaps)  
- **Cons:** bandwidth, lag, soft ink, burns CPU on armv7  

### B — Vector stroke stream (recommended primary)
- On pen move / pen-up, send **points + tool + color + width**  
- Desktop redraws with canvas2d / Skia  
- **Pros:** tiny bandwidth, crisp ink, low CPU, easy to record/export  
- **Cons:** must also send page clear/undo/shapes/AI bitmaps as separate events  

### C — Hybrid (recommended product)
1. **Live path:** vector strokes (B)  
2. **Resync:** full page PNG every N seconds or on AI answer / page flip (A)  
3. Desktop always has a correct picture even if a packet was lost  

---

## Recommended architecture

```
┌─────────────────────┐         LAN / USB          ┌──────────────────────────┐
│  reMarkable diary   │  TCP :27182  (or WS later) │  Desktop “Notepad Live”  │
│                     │ ─────────────────────────► │                          │
│  pen events →       │   NDJSON stroke frames     │  Windows / Mac / browser │
│  stroke streamer    │   + occasional page PNG    │  canvas viewer           │
└─────────────────────┘                            └──────────────────────────┘
         │                                                    │
         │ optional relay                                     │
         ▼                                                    ▼
   k8s / home server (later): multi-viewer, auth, recording
```

### Why tablet is the **server**
- Desktop connects **to** tablet IP (`172.16.10.175` Wi‑Fi or `10.11.99.1` USB)  
- No NAT traversal for home LAN  
- Multiple viewers can connect (Win + Mac at once)  

### Why not WebSocket first on-device
Full WS on bare C needs a library. MVP uses **newline-delimited JSON over TCP**. A tiny desktop bridge can expose WebSocket to a browser if needed.

### Protocol (NDJSON, one object per line)

```json
{"t":"hello","proto":1,"w":1404,"h":1872,"page":0,"pages":2}
{"t":"page","page":0,"pages":2}
{"t":"clear"}
{"t":"undo"}
{"t":"down","id":12,"tool":"pen","color":0,"width":1,"x":220,"y":400}
{"t":"move","id":12,"x":225,"y":404}
{"t":"move","id":12,"x":231,"y":410}
{"t":"up","id":12}
{"t":"shape","tool":"rect","color":0,"width":1,"x0":100,"y0":200,"x1":400,"y1":500}
{"t":"resync","fmt":"png","page":0,"n":12345}   // then raw length-prefixed PNG optional in v2
```

Coordinates: **canvas space** (same as notebook strokes), not screen (survives zoom/pan differences). Desktop maps canvas → window.

### Connection UX
1. Tablet Settings: **Live stream: on/off** + show IP + port  
2. Desktop app: “Connect to tablet” → IP field default `172.16.10.175:27182`  
3. Status: connected / reconnecting / idle  
4. Optional: SSH tunnel for when only USB is up:  
   `ssh -L 27182:127.0.0.1:27182 root@10.11.99.1` then connect to `localhost:27182`

### Security (MVP → later)
- MVP: LAN only, no auth (same as open SSH with password on home net)  
- Later: token in hello handshake, or TLS, or only via SSH tunnel  

### Performance budget (rM2)
- Coalesce `move` to ~30–60 Hz max (drop intermediate points if socket busy)  
- Non-blocking send; if buffer full, skip moves (keep down/up)  
- Never block the pen loop on network  

---

## Desktop app shape (Win + Mac = one codebase)

| Choice | Verdict |
|--------|---------|
| **Browser page** (`viewer/index.html`) | Fastest MVP; open on either OS |
| **Tauri / Electron shell** | Same HTML, installable app + tray icon later |
| **Native Swift / WinUI** | Two codebases — avoid for v1 |

MVP = browser viewer + optional Python bridge. Same URL on Win and Mac.

Features v1:
- Live ink canvas (white “paper”)  
- Connect / disconnect  
- Page indicator  
- “Fit to window”  

Features v2:
- Mirror AI answer bitmaps  
- Record session to JSON + replay  
- OBS-friendly window / transparent bg for meetings  
- Multi-page thumbnails  

---

## Implementation phases

### Phase 0 — Proof (optional, no diary change)
SSH loop: `SHELL_SHOT` / fb dump every 500 ms → desktop shows PNGs. Validates network only.

### Phase 1 — Stroke stream MVP  ← **this scaffold**
- `stream.c` / hooks in `diary.c`: TCP listen, emit down/move/up  
- Desktop `live-viewer/` HTML canvas client via a thin Node or Python WS↔TCP bridge  
- Settings toggle `stream=1` in `diary.conf`  

### Phase 2 — Productize
- Resync PNG on page change / AI render  
- Installable Tauri app  
- Menu icon “Live” on tablet rail  
- Auto-reconnect + USB fallback docs  

### Phase 3 — Polish
- Auth token, mDNS discovery (`sebbycorp-notepad.local`)  
- Meeting mode (hide chrome, large paper)  
- Optional relay through k8s-goose for remote (not home LAN)  

---

## Risks

| Risk | Mitigation |
|------|------------|
| Wi‑Fi sleep on tablet | USB path; stream keepalive; disable deep sleep while streaming |
| ETXTBSY / deploy | unchanged deploy flow |
| Lost moves | resync PNG; sequence numbers |
| Pen latency | non-blocking I/O; never wait on TCP in pen path |
| Firewall on Win/Mac | document allow inbound if tablet is client later; for server-on-tablet, desktop is outbound only (easier) |

---

## Decision

**Build hybrid stream (vector primary + resync), tablet TCP server, single web viewer for Win+Mac.**

Next code: Phase 1 scaffold under `remarkable-diary/live/` + hooks in takeover.
