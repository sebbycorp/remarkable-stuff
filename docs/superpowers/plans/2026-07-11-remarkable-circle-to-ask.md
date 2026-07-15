# Circle-to-Ask Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "AI on = answer the whole page after a pause" trigger with a circle-to-ask gesture: while AI is on, drawing a big closed loop around handwriting erases the loop, OCRs only that region, and renders the answer just below it.

**Architecture:** Add one pure, unit-tested geometry predicate (`is_lasso`) in a shared header. In the pen-up handler for freehand strokes, when AI is on and the just-drawn stroke passes `is_lasso`, undo the stroke (it was a command), flash a highlight box, and feed the stroke's screen-space bbox straight into the existing `ask_start` async OCR→model→render pipeline. Delete the old idle whole-page auto-ask block. Everything downstream of `ask_start` is reused unchanged.

**Tech Stack:** C (armv7 cross-compiled via toltec docker toolchain), reMarkable 2 takeover app under rm2fb, systemd `diary.service`. Host-side unit test compiled with the system `cc`.

**Repo/branch:** `/Users/sebbycorp/src/k8s-goose` on `feat/agent-desk`. Code dir: `remarkable-diary/takeover/`.

---

## File structure

- **Create** `remarkable-diary/takeover/lasso.h` — pure `is_lasso()` predicate + thresholds. Included by both `diary.c` and the host test. One responsibility: decide "is this finished stroke a circle-to-ask lasso?"
- **Create** `remarkable-diary/takeover/test_lasso.c` — host unit test for `is_lasso()`, compiled with system `cc` (not the armv7 toolchain).
- **Modify** `remarkable-diary/takeover/diary.c`:
  - include `lasso.h`
  - per-stroke screen bbox tracking in the pen loop
  - lasso branch in freehand pen-up
  - delete idle auto-ask block; simplify AI-toggle handler
  - footer hint text
- **Modify** `remarkable-diary/takeover/build.sh` — nothing required (diary.c picks up the new header automatically); no change unless the test is wired in (it is standalone).

**Coordinate convention:** all lasso geometry and the capture region are in **screen pixels**, consistent with `capture_png`/`ask_start` (which read the framebuffer). This is a deliberate v1 simplification of the spec's "canvas units" note — writing happens at base zoom, and thresholds in screen px behave correctly there. Zoom independence is out of scope.

---

### Task 1: Pure `is_lasso()` predicate + host unit test

**Files:**
- Create: `remarkable-diary/takeover/lasso.h`
- Test: `remarkable-diary/takeover/test_lasso.c`

- [ ] **Step 1: Write the failing test**

Create `remarkable-diary/takeover/test_lasso.c`:

```c
#include <stdio.h>
#include "lasso.h"

static int fails = 0;
static void check(const char* name, int got, int want){
  if(got!=want){ printf("FAIL %s: got %d want %d\n", name, got, want); fails++; }
  else printf("ok   %s\n", name);
}

int main(void){
  // big closed loop around text: bbox 400x300, ends 20px from start -> lasso
  check("big_closed_loop", is_lasso(100,200, 500,500, 100,200, 115,210), 1);
  // handwritten 'O': small bbox 40x50, closed -> not a lasso (too small)
  check("small_letter_O",  is_lasso(100,200, 140,250, 100,200, 102,205), 0);
  // big but open sweep (end far from start) -> not a lasso
  check("big_open_stroke", is_lasso(100,200, 500,500, 100,200, 480,480), 0);
  // wide but short underline: 400 wide, 30 tall -> not a lasso (one dim small)
  check("wide_short_line", is_lasso(100,200, 500,230, 100,200, 110,205), 0);
  // exactly at closed threshold boundary (60px away) counts as closed
  check("closed_boundary", is_lasso(100,200, 500,500, 100,200, 143,242), 1);

  if(fails){ printf("\n%d FAILED\n", fails); return 1; }
  printf("\nall passed\n"); return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
cc test_lasso.c -o test_lasso
```
Expected: FAIL to compile — `fatal error: 'lasso.h' file not found`.

- [ ] **Step 3: Write minimal implementation**

Create `remarkable-diary/takeover/lasso.h`:

```c
#ifndef LASSO_H
#define LASSO_H
// Circle-to-ask gesture detection (pure geometry; unit-tested on host).
//
// A finished FREEHAND pen stroke is treated as a "lasso" (a request to answer
// the enclosed content) only when it is BIG (encloses more than handwriting) in
// both dimensions AND CLOSED (pen-up lands near pen-down). Small closed shapes
// (letters like O/a/e) and big open sweeps (underlines, cross-outs) are ignored.
//
// All coordinates are in screen pixels. bx0..by1 is the stroke's bounding box;
// (downx,downy) is the pen-down point; (upx,upy) is the pen-up point.
#ifndef LASSO_MIN_PX
#define LASSO_MIN_PX   150   // min bbox width AND height to count as a lasso
#endif
#ifndef LASSO_CLOSE_PX
#define LASSO_CLOSE_PX  60   // max start->end distance to count as "closed"
#endif

static inline int is_lasso(int bx0,int by0,int bx1,int by1,
                           int downx,int downy,int upx,int upy){
  int w = bx1 - bx0, h = by1 - by0;
  if(w < LASSO_MIN_PX || h < LASSO_MIN_PX) return 0;   // too small = handwriting
  int dx = upx - downx, dy = upy - downy;
  if(dx*dx + dy*dy > LASSO_CLOSE_PX*LASSO_CLOSE_PX) return 0;  // not closed
  return 1;
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
cc test_lasso.c -o test_lasso && ./test_lasso
```
Expected: prints `ok` for all 5 cases then `all passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/sebbycorp/src/k8s-goose
git add remarkable-diary/takeover/lasso.h remarkable-diary/takeover/test_lasso.c
git commit -m "feat(diary): add is_lasso circle-to-ask predicate + host test"
```

---

### Task 2: Include the header and track per-stroke screen bbox

**Files:**
- Modify: `remarkable-diary/takeover/diary.c` (include near other headers; new locals in the pen loop ~`diary.c:1818`; pen-down reset ~`diary.c:1852`; ink-move extend ~`diary.c:1964`)

- [ ] **Step 1: Add the include**

Find the block of `#include` lines near the top of `diary.c` (after the stb/cJSON includes). Add:

```c
#include "lasso.h"
```

- [ ] **Step 2: Declare per-stroke bbox locals**

In `diary_screen`/main pen loop, find (`diary.c:1818`):

```c
  int bx0=1e9,by0=1e9,bx1=-1,by1=-1,dirty=0; long last_ink_ms=0;
```

Add directly below it:

```c
  // per-stroke screen-space bbox + pen-down point, for circle-to-ask lasso detection
  int sbx0=1000000,sby0=1000000,sbx1=-1,sby1=-1;
```

- [ ] **Step 3: Reset the per-stroke bbox on pen-down**

Find the pen-down reset line inside the `BTN_TOUCH` handler (`diary.c:1852`), which begins:

```c
        if(touch){downx=-1;downy=-1;moved=0;inmenu=0;inbar=0;inai=0;infooter=0;inprev=0;innext=0;inadd=0;inmodel=0;
```

Immediately after that line (before the `inzoomout=0;...` continuation or on the next line inside the same `if(touch){...}` block), add:

```c
          sbx0=1000000;sby0=1000000;sbx1=-1;sby1=-1;
```

- [ ] **Step 4: Extend the per-stroke bbox while drawing ink**

Find the freehand ink-move branch (`diary.c:1964`):

```c
            if(sx<bx0)bx0=sx;if(sy<by0)by0=sy;if(sx>bx1)bx1=sx;if(sy>by1)by1=sy;
            lx=sx;ly=sy; dirty=1; last_ink_ms=NOWMS();
```

Insert the per-stroke accumulation just above the `lx=sx;ly=sy;` line:

```c
            if(sx<bx0)bx0=sx;if(sy<by0)by0=sy;if(sx>bx1)bx1=sx;if(sy>by1)by1=sy;
            if(sx<sbx0)sbx0=sx;if(sy<sby0)sby0=sy;if(sx>sbx1)sbx1=sx;if(sy>sby1)sby1=sy;
            lx=sx;ly=sy; dirty=1; last_ink_ms=NOWMS();
```

- [ ] **Step 5: Verify it still builds (armv7)**

Run:
```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
./build.sh
```
Expected: `built: diary, ink (armv7)` with no compiler errors. (`is_lasso` is defined but not yet called — no warning because it's `static inline` in a header.)

- [ ] **Step 6: Commit**

```bash
cd /Users/sebbycorp/src/k8s-goose
git add remarkable-diary/takeover/diary.c
git commit -m "feat(diary): track per-stroke screen bbox for lasso detection"
```

---

### Task 3: Detect the lasso on freehand pen-up, erase it, and ask

**Files:**
- Modify: `remarkable-diary/takeover/diary.c` (freehand pen-up branch, `diary.c:1872`)

- [ ] **Step 1: Add the lasso branch at freehand pen-up**

Find the freehand pen-up branch (`diary.c:1872`):

```c
          } else if(screen==SCR_DIARY && live_idx>=0){
            // pen-up after writing: keep AI arm + idle clock fresh
            int pts=PG[curpage].st[live_idx].count;
            stroke_commit(live_idx); live_idx=-1;
            dirty=1; last_ink_ms=NOWMS(); nb_mark_save(last_ink_ms);
            if(bx1<=0 && !rubber){ bx0=downx>0?downx:40; by0=downy>0?downy:MODEL_BAR_H+40; bx1=bx0+80; by1=by0+40; }
            fprintf(stderr,"[diary] stroke commit nst=%d pts=%d pool=%d\n",PG[curpage].nst,pts,pool_n);
          } else if(screen==SCR_DIARY){
```

Replace it with (adds the lasso check between commit and the existing bookkeeping):

```c
          } else if(screen==SCR_DIARY && live_idx>=0){
            // pen-up after writing: keep AI arm + idle clock fresh
            int pts=PG[curpage].st[live_idx].count;
            stroke_commit(live_idx); live_idx=-1;
            // circle-to-ask: a big closed freehand loop, while AI is on, is a
            // request to answer what it encloses — not ink.
            if(ai_on && !rubber && !ask_busy && sbx1>0 &&
               is_lasso(sbx0,sby0,sbx1,sby1, downx,downy, lx,ly)){
              stroke_undo();                 // the loop was a command, remove it
              page_repaint(0);               // redraw the band without the loop
              rect_outline(sbx0,sby0,sbx1,sby1,3,gray565(90));  // highlight
              upd(sbx0,sby0,sbx1-sbx0,sby1-sby0,2,0);
              int rc=ask_start(sbx0,sby0,sbx1,sby1,cur_model);
              if(rc==1){ bar_msg("AI working…"); draw_diary_footer(); }
              else if(rc<0){ toast("AI start failed"); }
              // do NOT extend the page-wide bbox for a lasso
              nb_mark_save(NOWMS());
              lx=ly=-1;
              break;   // done handling this pen event batch
            }
            dirty=1; last_ink_ms=NOWMS(); nb_mark_save(last_ink_ms);
            if(bx1<=0 && !rubber){ bx0=downx>0?downx:40; by0=downy>0?downy:MODEL_BAR_H+40; bx1=bx0+80; by1=by0+40; }
            fprintf(stderr,"[diary] stroke commit nst=%d pts=%d pool=%d\n",PG[curpage].nst,pts,pool_n);
          } else if(screen==SCR_DIARY){
```

Note: `break` exits the inner `while(read(penfd,...))` event-drain loop after handling the lasso, so the freed pen-up state is clean before the next poll. `gray565` is the existing grey helper used throughout `draw_*`.

- [ ] **Step 2: Verify it builds (armv7)**

Run:
```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
./build.sh
```
Expected: `built: diary, ink (armv7)`, no errors. If `gray565` is reported undefined at this point, grep for the actual grey helper name (`grep -n "gray565\|grey565\|static.*gray" diary.c`) and use that — it is the same helper `rect_outline` callers already use (e.g. `diary.c:626`).

- [ ] **Step 3: Commit**

```bash
cd /Users/sebbycorp/src/k8s-goose
git add remarkable-diary/takeover/diary.c
git commit -m "feat(diary): circle-to-ask — lasso pen-up erases loop and asks region"
```

---

### Task 4: Remove the idle whole-page auto-ask and update chrome

**Files:**
- Modify: `remarkable-diary/takeover/diary.c` (idle block `diary.c:1972`; AI-toggle handler `diary.c:1894`; footer label `diary.c:1161`)

- [ ] **Step 1: Delete the idle auto-ask block**

Find (`diary.c:1972`):

```c
    // idle auto-ask: fork OCR+model so pen keeps working (was blocking = "AI on is slow")
    if(screen==SCR_DIARY&&ai_on&&dirty&&!ask_busy&&!touch&&live_idx<0&&bx1>0
       &&(NOWMS()-last_ink_ms)>(long)IDLE_SECS[set_idle]*1000
       &&(last_pen_ms==0||(NOWMS()-last_pen_ms)>(long)IDLE_SECS[set_idle]*1000)){
      dirty=0;
      int rc=ask_start(bx0,by0,bx1,by1,cur_model);
      if(rc==1){ bar_msg("AI working… keep writing"); draw_diary_footer(); }
      else if(rc<0) toast("AI start failed");
      // leave bbox so answer still anchors under the question
    }
```

Delete the entire block. Replace it with a one-line comment so the intent is documented:

```c
    // circle-to-ask replaces idle whole-page auto-ask: answers fire only from a
    // lasso gesture (see the freehand pen-up branch above).
```

- [ ] **Step 2: Simplify the AI-toggle handler**

Find (`diary.c:1894`):

```c
            else if(inai&&moved<45){
              if(ask_busy){ /* ignore while AI works */ }
              else {
                ai_on=!ai_on; settings_save();
                if(ai_on){
                  if(PG[curpage].nst>0) ARM_ASK();
                  else { dirty=0; bx0=1e9;by0=1e9;bx1=-1;by1=-1; }
                } else {
                  dirty=0; bx0=1e9;by0=1e9;bx1=-1;by1=-1;
                }
                draw_diary_footer();
              }
            }
```

Replace with (toggling AI on no longer arms a page-wide ask; it just enables lasso listening):

```c
            else if(inai&&moved<45){
              if(ask_busy){ /* ignore while AI works */ }
              else {
                ai_on=!ai_on; settings_save();
                dirty=0; bx0=1e9;by0=1e9;bx1=-1;by1=-1;   // no page-wide arm
                draw_diary_footer();
              }
            }
```

- [ ] **Step 3: Remove the now-unused ARM_ASK macro**

Find and delete the macro definition (`diary.c:1826`):

```c
  // Arm idle auto-ask: mark page dirty with a usable ink bbox.
  #define ARM_ASK() do { \
    dirty=1; last_ink_ms=NOWMS(); \
    if(bx1<=0){ bx0=40; by0=MODEL_BAR_H+40; bx1=(int)vinfo.xres-40; by1=MODEL_BAR_H+content_h()/3; } \
  } while(0)
```

- [ ] **Step 4: Update the footer AI label to hint the gesture**

Find (`diary.c:1161`):

```c
  const char* alab = ask_busy ? "AI…" : (ai_on?"AI on":"AI off");
```

Replace with:

```c
  const char* alab = ask_busy ? "AI…" : (ai_on?"circle to ask":"AI off");
```

- [ ] **Step 5: Verify it builds (armv7)**

Run:
```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
./build.sh
```
Expected: `built: diary, ink (armv7)`, no errors and no "ARM_ASK undeclared" (all references removed). If the compiler warns that `IDLE_SECS`/`set_idle` are now unused, that is acceptable — they still back the Settings screen.

- [ ] **Step 6: Re-run the host unit test (guards against header drift)**

Run:
```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
cc test_lasso.c -o test_lasso && ./test_lasso
```
Expected: `all passed`.

- [ ] **Step 7: Commit**

```bash
cd /Users/sebbycorp/src/k8s-goose
git add remarkable-diary/takeover/diary.c
git commit -m "feat(diary): remove idle whole-page ask; AI toggle = circle-to-ask mode"
```

---

### Task 5: Deploy to the tablet and verify end-to-end

**Files:** none (deploy + on-device verification)

Preconditions: tablet reachable. Wi-Fi reserved IP is `172.16.10.175`; USB is `10.11.99.1`. Key is `./id_diary` in the takeover dir. The app runs under `diary.service` (KillMode=process, so rm2fb survives a service stop).

- [ ] **Step 1: Confirm the armv7 binary is fresh**

Run:
```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
./build.sh && md5 diary
```
Expected: `built: diary, ink (armv7)` then an md5 — note it to confirm the deployed binary matches.

- [ ] **Step 2: Stop the service, replace the binary, restart**

Run (adjust `RM=172.16.10.175` if the tablet grabbed a different lease — see the project notes on querying the FortiGate DHCP table):
```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
RM=172.16.10.175
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i id_diary root@$RM"
SCP="scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i id_diary"
$SSH 'systemctl stop diary.service; rm -f /home/root/diary'
$SCP diary root@$RM:/home/root/diary
$SSH 'chmod +x /home/root/diary; md5sum /home/root/diary; systemctl start diary.service'
```
Expected: the on-device `md5sum` matches Step 1 (note macOS `md5` vs BusyBox `md5sum` print the same hash, different format). Service starts; `[diary] ready` appears in `journalctl -u diary.service`.

- [ ] **Step 3: On-device functional check (physical)**

On the tablet:
1. Enter the diary (Write). Tap the footer AI button until it reads **"circle to ask"**.
2. Write a short question, e.g. `what is kubernetes?`.
3. Draw a big circle around it.

Expected: the circle ink disappears, a highlight box flashes around the words, the footer shows "AI working…", and within a few seconds a handwritten answer renders just below the circled text. Confirm in logs:
```bash
ssh -i id_diary root@172.16.10.175 'journalctl -u diary.service -n 40 --no-pager | grep -i "ask async\|crop"'
```
Expected: an `[diary] ask async pid=… crop=WxH@x,y` line whose crop is the *circled region size*, not the full page.

- [ ] **Step 4: Negative check (physical)**

On the tablet, with AI reading "circle to ask": write a normal sentence and a small handwritten `O` inside a word, then wait. Expected: nothing is sent (no "AI working…"), because no stroke is big+closed enough. Writing a big circle with the **Ellipse shape tool** (from the menu) also must NOT trigger an ask — only freehand PEN loops do.

- [ ] **Step 5: Update project docs + memory**

Update `remarkable-diary/takeover/README.md` (the feature list) and the status doc `docs/superpowers/specs/2026-07-10-remarkable-sebbycorp-notepad-status.md` in the remarkable-stuff working dir to describe circle-to-ask replacing the idle whole-page trigger. Then commit:
```bash
cd /Users/sebbycorp/src/k8s-goose
git add remarkable-diary/takeover/README.md
git commit -m "docs(diary): document circle-to-ask gesture"
```

- [ ] **Step 6: Final verification statement**

Confirm all of: host test `all passed`; armv7 build clean; deployed md5 matches; a physical circle produced a region-sized crop and an answer; normal writing and a small O did not fire. Only then is the feature complete.

---

## Self-review notes

- **Spec coverage:** interaction model (Tasks 3+4), lasso heuristic freehand/closed/big (Task 1 predicate + Task 3 guard `!rubber` + PEN-only branch), erase-and-send (Task 3 `stroke_undo`+`ask_start`), highlight flash (Task 3 `rect_outline`+`upd`), answer below (reused `ask_start` `ask_anchor_y=by1+40`), idle removal (Task 4), footer hint (Task 4), edge cases empty/clamp/multi-page/busy (reused `ask_start` clamps + `!ask_busy` guard), verification (Task 5 incl. negative checks). Covered.
- **Coordinate simplification vs spec:** spec mentioned canvas units for zoom independence; this plan uses screen px throughout (consistent with the capture pipeline) and documents it as a v1 scope decision. No functional gap at base zoom.
- **Type/name consistency:** `is_lasso` signature identical in `lasso.h`, `test_lasso.c`, and the `diary.c` call. Helpers used (`stroke_undo`, `page_repaint`, `rect_outline`, `upd`, `bar_msg`, `toast`, `ask_start`, `draw_diary_footer`, `gray565`) all verified present in `diary.c`.
