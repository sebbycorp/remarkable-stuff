# Teleprompter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native Teleprompter to SebbyCorp Notepad that lists `scripts/*.md` from `sebbycorp/web-telepromotor` and stages spoken quote lines on a black portrait screen.

**Architecture:** Pure parser/list helpers live in `prompter.c` / `prompter.h` (host-testable). `diary.c` gains `SCR_PROMPTER` + `SCR_PROMPTER_RUN`, a Home card, curl fetch, and stage input. No sidecar process, no script cache, no new systemd unit.

**Tech Stack:** C (host `cc` for tests, existing armv7 `build.sh` for the tablet), cJSON, curl via `popen`, existing framebuffer UI in `diary.c`.

**Code repo:** `/Users/sebbycorp/src/k8s-goose/remarkable-diary` (branch `feat/agent-desk`). Spec lives in `remarkable-stuff`.

**Spec:** `docs/superpowers/specs/2026-08-13-remarkable-teleprompter-design.md`

---

## File map

| File | Responsibility |
|---|---|
| `takeover/prompter.h` | Types + API: parse markdown, fit/split steps, parse GitHub contents JSON |
| `takeover/prompter.c` | Implementation (no framebuffer, no network) |
| `takeover/test_prompter.c` | Host unit tests + embedded fixtures |
| `takeover/diary.c` | Screens, Home card, curl GET, draw, tap, play timer |
| `takeover/build.sh` | Link `prompter.c` into `diary` |

---

### Task 1: Parser — empty / no quotes

**Files:**
- Create: `takeover/prompter.h`
- Create: `takeover/prompter.c`
- Create: `takeover/test_prompter.c`

- [ ] **Step 1: Write the failing test**

`takeover/test_prompter.c`:

```c
#include <stdio.h>
#include <string.h>
#include "prompter.h"

static int fails = 0;
static void check(const char* name, int got, int want){
  if(got!=want){ printf("FAIL %s: got %d want %d\n", name, got, want); fails++; }
  else printf("ok   %s\n", name);
}
static void check_str(const char* name, const char* got, const char* want){
  if(!got || strcmp(got,want)){ printf("FAIL %s: got '%s' want '%s'\n", name, got?got:"(null)", want); fails++; }
  else printf("ok   %s\n", name);
}

int main(void){
  PrompterScript s; prompter_script_init(&s);
  check("empty_n", prompter_parse("", &s), 0);
  prompter_script_free(&s);

  prompter_script_init(&s);
  check("no_quotes", prompter_parse("# Title\n\n**HOST:**\n\nplain text\n", &s), 0);
  prompter_script_free(&s);

  if(fails){ printf("\n%d FAILED\n", fails); return 1; }
  printf("\nall passed\n"); return 0;
}
```

`takeover/prompter.h` (declarations only — do not implement parse yet beyond stubs if the test cannot link; prefer missing symbol so the first run fails to compile, then add empty stubs that return 0):

```c
#ifndef PROMPTER_H
#define PROMPTER_H

#define PROMPTER_MAX_STEPS 128
#define PROMPTER_STEP_CAP  2048
#define PROMPTER_FIT_CHARS 280
#define PROMPTER_MAX_FILES 32

typedef struct {
  char *steps[PROMPTER_MAX_STEPS];
  int n;
} PrompterScript;

void prompter_script_init(PrompterScript *s);
void prompter_script_free(PrompterScript *s);
int  prompter_parse(const char *md, PrompterScript *out);
int  prompter_fit_step(const char *text, int max_chars, PrompterScript *out);
int  prompter_parse_fit(const char *md, int max_chars, PrompterScript *out);

typedef struct {
  char name[64];
  char download[256];
} PrompterFile;

int prompter_parse_list(const char *json, PrompterFile *out, int cap);

#endif
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
cc -O2 -Wall -Wextra -o test_prompter test_prompter.c
```

Expected: FAIL to compile (`prompter.h` missing or `prompter_parse` undefined).

- [ ] **Step 3: Minimal implementation so the empty cases pass**

`takeover/prompter.c`:

```c
#include "prompter.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "cJSON.h"

void prompter_script_init(PrompterScript *s){
  if(!s) return;
  memset(s, 0, sizeof *s);
}
void prompter_script_free(PrompterScript *s){
  if(!s) return;
  for(int i=0;i<s->n;i++) free(s->steps[i]);
  memset(s, 0, sizeof *s);
}
int prompter_parse(const char *md, PrompterScript *out){
  if(!out) return 0;
  prompter_script_free(out);
  if(!md || !md[0]) return 0;
  return 0; /* quotes added in Task 2 */
}
int prompter_fit_step(const char *text, int max_chars, PrompterScript *out){
  (void)text; (void)max_chars; (void)out; return 0;
}
int prompter_parse_fit(const char *md, int max_chars, PrompterScript *out){
  (void)md; (void)max_chars; (void)out; return 0;
}
int prompter_parse_list(const char *json, PrompterFile *out, int cap){
  (void)json; (void)out; (void)cap; return 0;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cc -O2 -Wall -Wextra -o test_prompter test_prompter.c prompter.c cJSON.c
./test_prompter
```

Expected: `all passed`

- [ ] **Step 5: Commit**

```bash
git add takeover/prompter.h takeover/prompter.c takeover/test_prompter.c
git commit -m "test: teleprompter parser empty and no-quote cases"
```

---

### Task 2: Parser — extract spoken quotes

**Files:**
- Modify: `takeover/prompter.c`
- Modify: `takeover/test_prompter.c`

- [ ] **Step 1: Add failing tests for quote extraction**

Append before `if(fails)` in `main`:

```c
  {
    const char* md =
      "# Title\n\n"
      "**HOST:**\n"
      "> Hello world.\n\n"
      "**[VISUAL: card]**\n\n"
      "> Second line.\n"
      "> Still second.\n\n"
      "## YouTube Description\n\n"
      "> A walkthrough of Agent Registry\n";
    PrompterScript s; prompter_script_init(&s);
    check("quotes_n", prompter_parse(md, &s), 3);
    check_str("q0", s.n>0?s.steps[0]:"", "Hello world.");
    check_str("q1", s.n>1?s.steps[1]:"", "Second line. Still second.");
    check_str("q2", s.n>2?s.steps[2]:"", "A walkthrough of Agent Registry");
    prompter_script_free(&s);
  }
  {
    const char* md = "  >  indented quote  \n";
    PrompterScript s; prompter_script_init(&s);
    check("indent_n", prompter_parse(md, &s), 1);
    check_str("indent", s.n>0?s.steps[0]:"", "indented quote");
    prompter_script_free(&s);
  }
```

Note: the YouTube description in this fixture is *also* a blockquote, so it **is** a spoken step. The real `agent-registry.md` description uses `>` too — Task 3 handles skipping that section by heading name.

- [ ] **Step 2: Run and confirm `quotes_n` fails (got 0 want 3)**

```bash
cc -O2 -Wall -Wextra -o test_prompter test_prompter.c prompter.c cJSON.c && ./test_prompter
```

- [ ] **Step 3: Implement `prompter_parse`**

Walk `md` line by line. A line is a quote if after leading spaces it starts with `>`. Strip `>` and one following space. Consecutive quote lines join with a single space. A blank line or non-quote line flushes the current step. Trim trailing/leading whitespace on each step. Ignore empty steps. Cap at `PROMPTER_MAX_STEPS`. Each step is `strdup` of at most `PROMPTER_STEP_CAP-1` chars.

- [ ] **Step 4: Tests pass**

- [ ] **Step 5: Commit**

```bash
git add takeover/prompter.c takeover/test_prompter.c
git commit -m "feat: parse teleprompter spoken quotes from markdown"
```

---

### Task 3: Parser — skip YouTube Description / Title options

**Files:**
- Modify: `takeover/prompter.c`
- Modify: `takeover/test_prompter.c`

- [ ] **Step 1: Failing test**

```c
  {
    const char* md =
      "## 0:00 — OPEN\n\n"
      "> When you build an AI agent, you're not really building one thing.\n\n"
      "## YouTube Description\n\n"
      "> A walkthrough of Agent Registry\n\n"
      "## Title options\n\n"
      "> ignored even if quoted\n";
    PrompterScript s; prompter_script_init(&s);
    check("skip_tail_n", prompter_parse(md, &s), 1);
    check_str("skip_tail", s.n>0?s.steps[0]:"",
              "When you build an AI agent, you're not really building one thing.");
    prompter_script_free(&s);
  }
```

- [ ] **Step 2: Run — `skip_tail_n` got 3 want 1**

- [ ] **Step 3: Implement skip**

If a heading line (`#` after trim) contains `YouTube Description` or starts with `Title options` (case-sensitive as in the real files), stop parsing — do not consume further lines.

- [ ] **Step 4: Tests pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: drop YouTube description and title options from prompter"
```

---

### Task 4: Fit / sentence split

**Files:**
- Modify: `takeover/prompter.c`
- Modify: `takeover/test_prompter.c`

- [ ] **Step 1: Failing tests**

```c
  {
    PrompterScript s; prompter_script_init(&s);
    check("fit_short", prompter_fit_step("Hello world.", 280, &s), 1);
    check_str("fit_short_s", s.steps[0], "Hello world.");
    prompter_script_free(&s);
  }
  {
    PrompterScript s; prompter_script_init(&s);
    const char* long2 =
      "First sentence is fairly long and should stay whole. "
      "Second sentence is also fairly long and becomes its own step.";
    check("fit_two", prompter_fit_step(long2, 50, &s), 2);
    check_str("fit_two_0", s.steps[0], "First sentence is fairly long and should stay whole.");
    check_str("fit_two_1", s.steps[1], "Second sentence is also fairly long and becomes its own step.");
    prompter_script_free(&s);
  }
  {
    PrompterScript s; prompter_script_init(&s);
    check("fit_one_sentence", prompter_fit_step("ThisIsOneVeryLongWordWithoutSpacesOrPunctuationXXXXXXXX", 10, &s), 1);
    prompter_script_free(&s);
  }
  {
    PrompterScript s; prompter_script_init(&s);
    const char* md = "> Short one.\n\n> First sentence here. Second sentence here.\n";
    check("parse_fit_n", prompter_parse_fit(md, 20, &s), 3);
    prompter_script_free(&s);
  }
```

- [ ] **Step 2: Run — `fit_short` fails (got 0)**

- [ ] **Step 3: Implement**

`prompter_fit_step`: if `strlen(text) <= max_chars` (or `max_chars<=0`), append one copy and return 1. Else scan for `.`, `?`, `!` followed by space or end. Each sentence is one piece. If a sentence itself is longer than `max_chars`, still one piece (word-wrap is draw-time). Append via an internal `prompter_add(out, text)` helper used by parse too.

`prompter_parse_fit`: parse into a temp script, fit each step into `out`.

- [ ] **Step 4: Tests pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: split over-long prompter steps on sentences"
```

---

### Task 5: GitHub contents JSON list

**Files:**
- Modify: `takeover/prompter.c`
- Modify: `takeover/test_prompter.c`

- [ ] **Step 1: Failing test**

```c
  {
    const char* json =
      "["
      "{\"name\":\"agent-registry.md\",\"type\":\"file\","
      "\"download_url\":\"https://raw.githubusercontent.com/sebbycorp/web-telepromotor/main/scripts/agent-registry.md\"},"
      "{\"name\":\"README.txt\",\"type\":\"file\",\"download_url\":\"https://example.com/README.txt\"},"
      "{\"name\":\"scripts\",\"type\":\"dir\",\"download_url\":null}"
      "]";
    PrompterFile files[8];
    int n = prompter_parse_list(json, files, 8);
    check("list_n", n, 1);
    check_str("list_name", n>0?files[0].name:"", "agent-registry");
    check("list_url", n>0 && strstr(files[0].download, "agent-registry.md")!=NULL, 1);
  }
  {
    check("list_bad", prompter_parse_list("not json", NULL, 0), 0);
    check("list_empty_arr", prompter_parse_list("[]", NULL, 8), 0);
  }
```

- [ ] **Step 2: Run — `list_n` got 0 want 1**

- [ ] **Step 3: Implement `prompter_parse_list`**

`cJSON_Parse` the array. For each object: `type=="file"` and `name` ends with `.md`. Copy name without `.md` into `out[i].name` (truncate to 63). Copy `download_url` (truncate to 255). Skip if `download_url` missing. Return count.

- [ ] **Step 4: Tests pass**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: parse GitHub scripts/ contents into teleprompter list"
```

---

### Task 6: Fixture against real agent-registry.md

**Files:**
- Create: `takeover/testdata/agent-registry.md` (copy of the live file)
- Modify: `takeover/test_prompter.c`

- [ ] **Step 1: Failing test**

Copy https://raw.githubusercontent.com/sebbycorp/web-telepromotor/main/scripts/agent-registry.md to `takeover/testdata/agent-registry.md`.

Add a test that reads the file (path relative to cwd `takeover/`) and asserts:

- `prompter_parse_fit(buf, 280, &s) > 5`
- no step contains `YouTube Description`
- no step contains `Title options`
- no step contains `[VISUAL`
- first step starts with `When you build an AI agent`

- [ ] **Step 2: Run from `takeover/` — fail until file is read + parse_fit used**

- [ ] **Step 3: If parse already correct, test passes. If the description quotes leaked, tighten Task 3 heading match (`## YouTube Description`).**

- [ ] **Step 4: Tests pass**

- [ ] **Step 5: Commit**

```bash
git add takeover/testdata/agent-registry.md takeover/test_prompter.c
git commit -m "test: parse real agent-registry teleprompter script"
```

---

### Task 7: Home card + screen enum

**Files:**
- Modify: `takeover/diary.c` (enum ~line 76, `draw_card` ~1947, `draw_home` ~2511, `handle_tap` ~2715, `enter_screen` ~2686)
- Modify: `takeover/build.sh`

- [ ] **Step 1: No host UI test — visual on device. Implement directly after parser is green.**

- [ ] **Step 2: Wire the binary**

`build.sh` compile line becomes:

```sh
  sh -c "$GCC -O2 diary.c prompter.c cJSON.c -o diary -lm && $GCC -O2 ink.c -o ink"
```

`diary.c`:

```c
#include "prompter.h"
enum { SCR_HOME, SCR_DIARY, SCR_LIBRARY, SCR_SETTINGS, SCR_PROMPTER, SCR_PROMPTER_RUN };
```

Add `ic_prompter` (two stacked horizontal lines + a play triangle) and in `draw_card`:

```c
  if(which==0) ic_write(icx,icy,is);
  else if(which==1) ic_library(icx,icy,is);
  else if(which==3) ic_prompter(icx,icy,is);
  else ic_gear(icx,icy,is);
```

Home hit zones: insert Teleprompter between Library and Settings.

```c
static int HOME_PRO_Y0, HOME_PRO_Y1;
// in draw_home:
  HOME_LIB_Y0=580; HOME_LIB_Y1=700;
  HOME_PRO_Y0=716; HOME_PRO_Y1=836;
  HOME_SET_Y0=852; HOME_SET_Y1=972;
  draw_card(68,HOME_LIB_Y0,W-68,HOME_LIB_Y1,"Library","saved AI pages",1);
  draw_card(68,HOME_PRO_Y0,W-68,HOME_PRO_Y1,"Teleprompter","scripts from GitHub",3);
  draw_card(68,HOME_SET_Y0,W-68,HOME_SET_Y1,"Settings","model, sleep, boot",2);
```

`handle_tap` Home:

```c
    if(sy>=HOME_PRO_Y0 && sy<=HOME_PRO_Y1){ enter_screen(SCR_PROMPTER); return; }
```

Stub `draw_prompter_list` / `draw_prompter_run` as paper/black screens with title + Home so navigation works before fetch lands.

`enter_screen`:

```c
  if(s==SCR_PROMPTER) draw_prompter_list();
  else if(s==SCR_PROMPTER_RUN) draw_prompter_run();
```

- [ ] **Step 3: Host parser tests still pass**

```bash
cc -O2 -Wall -Wextra -o test_prompter test_prompter.c prompter.c cJSON.c && ./test_prompter
```

- [ ] **Step 4: Commit**

```bash
git add takeover/diary.c takeover/build.sh
git commit -m "feat: Teleprompter Home card and screen stubs"
```

---

### Task 8: Fetch list + draw list

**Files:**
- Modify: `takeover/diary.c`

- [ ] **Step 1: Implement GET + list state**

```c
#define PROMPTER_LIST_URL \
  "https://api.github.com/repos/sebbycorp/web-telepromotor/contents/scripts"

static PrompterFile pro_files[PROMPTER_MAX_FILES];
static int pro_n=0;
static char pro_status[96];
static PrompterScript pro_script;
static int pro_i=0;
static int pro_playing=0;
static long pro_next_ms=0;
#define PROMPTER_STEP_MS 4000L
```

`http_get_url(const char* url)`: `popen`  
`curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' -H 'User-Agent: sebbycorp-notepad' '<url>'`  
read all stdout, `pclose`, return malloc'd buffer or NULL.

On `enter_screen(SCR_PROMPTER)`:

```c
  pro_n = 0;
  snprintf(pro_status, sizeof pro_status, "Loading scripts...");
  draw_prompter_list(); /* first paint so the user sees loading */
  char* js = http_get_url(PROMPTER_LIST_URL);
  if(!js){ snprintf(pro_status,sizeof pro_status,"Can't reach GitHub. Check Wi-Fi."); }
  else {
    pro_n = prompter_parse_list(js, pro_files, PROMPTER_MAX_FILES);
    free(js);
    if(pro_n==0) snprintf(pro_status,sizeof pro_status,"No scripts in scripts/.");
    else pro_status[0]=0;
  }
  draw_prompter_list();
```

`draw_prompter_list`: paper, Home corner, title `Teleprompter`, hint `sebbycorp/web-telepromotor`. If `pro_status[0]`, center that sentence. Else rows like Library (`rrect` + name + subtitle `markdown`). Store row Y in `PRO_ROW_Y[]`.

`handle_tap` on `SCR_PROMPTER`: Home (`sy<170 && sx<140`) → `SCR_HOME`. Else if hit row i → Task 9 load.

- [ ] **Step 2: Commit**

```bash
git commit -am "feat: load teleprompter script list from GitHub"
```

---

### Task 9: Load script + stage

**Files:**
- Modify: `takeover/diary.c`

- [ ] **Step 1: Open + draw stage**

On row tap:

```c
  snprintf(pro_status,sizeof pro_status,"Loading %s...", pro_files[idx].name);
  draw_prompter_list();
  char* md = http_get_url(pro_files[idx].download);
  if(!md){
    snprintf(pro_status,sizeof pro_status,"Couldn't load %s.", pro_files[idx].name);
    draw_prompter_list(); return;
  }
  prompter_script_free(&pro_script);
  prompter_parse_fit(md, PROMPTER_FIT_CHARS, &pro_script);
  free(md);
  if(pro_script.n==0){
    snprintf(pro_status,sizeof pro_status,"No spoken lines in this file.");
    draw_prompter_list(); return;
  }
  pro_i=0; pro_playing=0; pro_next_ms=0;
  enter_screen(SCR_PROMPTER_RUN);
```

`draw_prompter_run`:

- `rect_fill` entire fb black
- chrome grey `gray565(80)`: `Home` top-left, `play`/`pause` top-right (`mtext` with `g_glyph_inv`)
- body: current `pro_script.steps[pro_i]` wrapped with existing word-wrap idea at 52px, white (`mtext_w`), margins 80, y start ~280
- footer: `snprintf("%d / %d", pro_i+1, pro_script.n)`
- `shell_upd()`

Word wrap: walk words, if `text_w` exceeds `W-160` break line. Advance y by line height (~64). Stop if y would hit footer.

Hit zones:

```c
static int PRO_HOME_X1=140, PRO_HOME_Y1=170;
static int PRO_PLAY_X0, PRO_PLAY_Y0=40, PRO_PLAY_X1, PRO_PLAY_Y1=170;
```

Set `PRO_PLAY_X0 = W-200` in draw.

`handle_tap` `SCR_PROMPTER_RUN`:

- Home box → `prompter_script_free`, `pro_playing=0`, `enter_screen(SCR_PROMPTER)` (refetch list)
- Play box → toggle `pro_playing`; if on, `pro_next_ms = mono_ms()+PROMPTER_STEP_MS`
- `sy < vinfo.yres*15/100` → `if(pro_i>0) pro_i--`; redraw
- else → `if(pro_i+1<pro_script.n) pro_i++`; redraw

- [ ] **Step 2: Commit**

```bash
git commit -am "feat: teleprompter stage with tap next/back"
```

---

### Task 10: Play timer

**Files:**
- Modify: `takeover/diary.c` main loop (~after autosave block, before end of `while(running)`)

- [ ] **Step 1: Advance on timer**

```c
    if(screen==SCR_PROMPTER_RUN && pro_playing){
      long now=NOWMS();
      if(now>=pro_next_ms){
        if(pro_i+1<pro_script.n){
          pro_i++;
          pro_next_ms=now+PROMPTER_STEP_MS;
          draw_prompter_run();
        } else {
          pro_playing=0;
          draw_prompter_run();
        }
      }
    }
```

Poll timeout is already 200 ms — fine for 4 s steps.

- [ ] **Step 2: Host tests still pass. Commit**

```bash
git commit -am "feat: teleprompter play auto-advance"
```

---

### Task 11: Verify + status doc

**Files:**
- Modify: `remarkable-stuff/docs/superpowers/specs/2026-07-10-remarkable-sebbycorp-notepad-status.md` after on-device confirm
- Test: `takeover/test_prompter`

- [ ] **Step 1: Host**

```bash
cd /Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover
cc -O2 -Wall -Wextra -o test_prompter test_prompter.c prompter.c cJSON.c && ./test_prompter
```

Expected: `all passed`

- [ ] **Step 2: Cross-compile**

```bash
./build.sh
```

Expected: `built: diary, ink (armv7)`

- [ ] **Step 3: On-device (when USB/Wi-Fi up)**

```bash
./deploy.sh 10.11.99.1 ./id_diary   # or 172.16.10.175
```

Walk: Home card → list (3 scripts) → `agent-registry` first line → tap next/back → play stops at end → Home to list → Home to notepad. Airplane mode → can't-reach. Write/Library/Settings unchanged.

- [ ] **Step 4: Update notepad status UX map** (only after the walk passes)

```
Home
├── Write
├── Library
├── Teleprompter  → list (GitHub scripts/) → stage
├── Settings
├── Sleep
└── Exit to reMarkable
```

- [ ] **Step 5: Final commit**

```bash
git commit -am "docs: teleprompter shipped on notepad Home"
```

---

## Self-review (plan vs spec)

| Spec item | Task |
|---|---|
| Home Teleprompter card | 7 |
| List paper chrome | 8 |
| Stage black + white | 9 |
| Tap next / top strip back | 9 |
| Play 4 s, stop on last | 10 |
| Portrait only | 7–9 (no rotate) |
| Repo hardcoded | 8 `PROMPTER_LIST_URL` |
| Spoken quotes only | 2 |
| Skip description / titles | 3 |
| Sentence split if too tall | 4 |
| Can't reach / no scripts / no spoken | 8–9 |
| curl GET | 8 |
| Gateway TLS hop | **Deferred:** curl first; add hop only if on-device curl cannot speak HTTPS |
| Off-device parser tests | 1–6 |
| On-device walk | 11 |
| No cache / no settings keys / no remote | honored (not in tasks) |
