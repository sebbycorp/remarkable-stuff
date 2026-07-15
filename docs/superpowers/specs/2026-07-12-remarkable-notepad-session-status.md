# SebbyCorp Notepad — session status (2026-07-12)

**Code:** `/Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover/`  
**Branch:** `feat/agent-desk`  
**Device:** reMarkable 2 @ `10.11.99.1` (USB) / `172.16.10.175` (Wi‑Fi)  
**Deploy:** `./deploy.sh 10.11.99.1 ./id_diary` (or stop service → scp `diary` → start)

---

## What shipped this session

### 1. Dot paper (4 dpi)
- Generator: `remarkable-stuff/paper/generate_dot_paper.py`
- Output: `paper/out/dots-4dpi-rm2.png`, `.pdf`, `50p.pdf`
- **On-device template:** native `P Dots 4dpi.template` installed under  
  `/usr/share/remarkable/templates/` with `templates.json` entry  
  **Name in picker:** “Dots 4 per inch” (portrait + landscape)  
- Pitch: ¼″ (4 dots/inch), unit pitch `63.5` (0.1 mm scale)

### 2. UI redesign (fonts, chrome, less boxy)
- **UI font:** Atkinson Hyperlegible (`diary-resp.ttf` / mirrored as `diary-menu.ttf`)
- Larger type across home, settings, menu, footer
- Soft rounded rects + true circular buttons
- Monoline icons (write, book, gear, tools, trash, home, etc.)
- Deploy also copies Atkinson to device as both UI + answer face

### 3. Home / menus / settings (pass “D”)
**Home**
- Tappable **model** + **AI on/off** chips
- Hero **Continue writing** (pages + stroke count)
- Secondary Library / Settings rows
- Sleep / Exit as quiet text links

**Write menu (left rail)**
- Sections: `TOOLS` · `INK` · `PAGE` · `APP`
- Style chips: solid / dash / dot  
- Width chips: S / M / L  

**Settings**
- Groups: **AI** (model 2×2 chips, size, font) · **DEVICE** (sleep, boot)
- Exit demoted to footer text link

### 4. Circle-to-ask (writing → typed text → answer)
**Intended UX**
1. Write by hand (e.g. `2+2`, `who is batman`)
2. Circle with AI on  
3. Loop removed  
4. Handwriting **erased**  
5. **Typed OCR** of the question in that place  
6. **Answer below** (light rule between)

**Hardening**
- Erase by **bbox intersection** (+ pad), not center-only  
- Full-width white band before typing  
- **Opaque** answer bitmaps so white covers old ink (no ghost handwriting)  
- Safer text margins: `TEXT_LEFT=96`, `TEXT_RIGHT_PAD=96`  
- Full-width opaque capture so left edge isn’t cropped on re-blit  
- Opaque flag packed into high bit of `bw` in notebook save format  

**Failures:** OCR/model fail leaves ink intact (no erase).

### 5. Diagrams (Mermaid + layout)
- Prompt prefers `{"kind":"mermaid","src":"flowchart TD\\n ..."}`  
- On-device Mermaid subset parser: TD/LR, rect/diamond/circle/round, edges + labels  
- Improved auto-layout: layered, orthogonal elbows, clean UI font labels  
- JSON `flow` still supported via same engine  

### 6. Agent tables (@k8s / @f5)
- Compact `render_table`: smaller type, auto height fit, zebra + header band  
- Cell truncate with `..`  
- Denser `render_stats` tiles  

---

## Key files

| Path | Role |
|------|------|
| `takeover/diary.c` | Full shell + canvas + AI + render |
| `takeover/lasso.h` | Circle-to-ask geometry |
| `takeover/deploy.sh` | Build + scp + fonts + restart |
| `takeover/README.md` | Product guide |
| `paper/generate_dot_paper.py` | 4 dpi paper generator |
| `paper/P Dots 4dpi.template` | Native rM template |
| `agent-desk/` | @k8s / @f5 / @forti → render-spec JSON |

---

## On-device paths

| Path | Purpose |
|------|---------|
| `/home/root/diary` | Binary |
| `/home/root/diary-resp.ttf` | Atkinson (UI + clean answers) |
| `/home/root/diary-menu.ttf` | Atkinson (deployed; legacy name) |
| `/home/root/diary-mono.ttf` | Mono (tables / mono answer font) |
| `/home/root/diary-font.ttf` | Cursive answers |
| `/home/root/diary.conf` | Settings |
| `/home/root/diary-nb/notebook.dnb` | Notebook persistence |
| `/usr/share/remarkable/templates/P Dots 4dpi.template` | Dot paper template |

---

## How to rebuild / deploy

```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
./build.sh
# Prefer stop first if ETXTBSY:
ssh -i id_diary root@10.11.99.1 \
  'systemctl stop diary.service; kill -9 $(ps|grep "[/]home/root/diary"|awk "{print \$1}"); rm -f /home/root/diary'
scp -i id_diary diary root@10.11.99.1:/home/root/diary
scp -i id_diary AtkinsonHyperlegible-Regular.ttf root@10.11.99.1:/home/root/diary-resp.ttf
scp -i id_diary AtkinsonHyperlegible-Regular.ttf root@10.11.99.1:/home/root/diary-menu.ttf
ssh -i id_diary root@10.11.99.1 'chmod +x /home/root/diary; systemctl start diary.service'
```

Or: `./deploy.sh 10.11.99.1 ./id_diary` (may hit ETXTBSY if service holds the binary).

**UI screenshots:** set `SHELL_SHOT=home|settings|menu|diary|library` with  
`LD_PRELOAD=/opt/lib/librm2fb_client.so` → `/home/root/demo-out.png`

---

## Known caveats / follow-ups

- Old notebook pages may still show **ghost bitmaps** from pre-opaque captures → use **new page** or **Clear page** once.  
- Left margin / full-width capture fixed late in session; re-test circle-to-ask on a clean page.  
- Mermaid is a **subset** (no subgraphs/styles/links).  
- Agent table density is on-device only; agent-desk prompts can still be tightened for shorter cell values.  
- Template install requires **USB/SSH** and may need re-install after OS update (`templates.json` reset).  

---

## Related earlier designs

- `2026-07-11-remarkable-circle-to-ask-design.md`  
- `2026-07-10-remarkable-sebbycorp-notepad-status.md`  
- `2026-07-10-remarkable-diary-shell-settings-design.md`  
- `2026-07-07-remarkable-agent-desk-design.md`  
