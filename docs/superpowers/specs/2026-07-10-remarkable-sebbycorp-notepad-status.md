# SebbyCorp Notepad — product status

**Date:** 2026-07-10  
**Status:** Shipped on-device (takeover)  
**Code:** `k8s-goose/remarkable-diary/takeover/diary.c`  
**Brand:** Home title **SebbyCorp Notepad**, subtitle *from diary OS*

## Summary

The reMarkable 2 takeover app is a multi-screen shell with a hybrid multi-page / tall vector notebook, shape tools, finger pan/zoom, model selection, and optional AI answers via agentgateway.

## Feature matrix

| Area | Status | Notes |
|---|---|---|
| Home launcher | ✅ | Write / Library / Settings cards; Sleep + Exit soft links |
| Settings | ✅ | Model, answer size/font, auto-ask delay, sleep; label left / value right |
| Multi-page Write | ✅ | Page nav, add page, delete page (2-tap) |
| Tall vector canvas | ✅ | 3× content height; strokes vector |
| Finger pan / pinch zoom | ✅ | event2 `pt_mt`; zoom % when ≠100% |
| Shape tools | ✅ | pen, rect, oval, tri, line, arrow + style/width |
| Undo | ✅ | Last stroke |
| Persist notebook | ✅ | `/home/root/diary-nb/notebook.dnb` |
| AI on/off | ✅ | Idle auto-ask only when AI on |
| Model switcher | ✅ | Footer chip + Settings |
| Save PDF to library | ✅ | Menu Save |
| In-app library | ✅ | AI diary PDFs |
| Teleprompter | ✅ | Home card; GitHub `scripts/*.md`; spoken quotes; tap + 4s play |
| Markmaps / flow / agents | ✅ | `@forti` `@f5` `@k8s` via agent-desk |
| Watchdog systemd | ✅ | Boots into shell |
| Ask button | ❌ removed | Redundant with AI on/off |
| Empty-state hint text | ❌ removed | User preference |
| Stamps / move stamp | ❌ removed | User preference (2026-07-10) |

## Paths on tablet

| Path | Purpose |
|---|---|
| `/home/root/diary` | Binary |
| `/home/root/diary.conf` | Settings |
| `/home/root/diary-nb/notebook.dnb` | Notebook strokes + bitmaps |
| `/home/root/diary-menu.ttf` | Special Elite UI font |
| `/home/root/diary-font.ttf` | Cursive answers |
| `/home/root/diary-mono.ttf` | Tables/metrics |

## Deploy

```bash
cd remarkable-diary/takeover
./build.sh
./deploy.sh 172.16.10.175 ./id_diary
```

Tablet: reMarkable 2, OS 3.22.4.2, rm2fb, Wi-Fi `172.16.10.175`.

## UX map

```
Home
├── Write  → top: menu | tool chip | date | battery
│            footer: pages | + | model | AI
│            menu: tools grid | style | width | page actions
├── Library
├── Teleprompter  → GitHub scripts/ list → black stage
├── Settings
├── Sleep
└── Exit to reMarkable
```

## Design lineage

1. Shell + settings → implemented  
2. Canvas v2 (vector + finger + persist) → implemented  
3. UI polish pass → implemented  
4. Stamps + move → implemented, then removed (2026-07-10, user preference)  

See sibling specs dated 2026-07-07 … 2026-07-10 for original designs; this file is the **source of truth for what shipped**.
