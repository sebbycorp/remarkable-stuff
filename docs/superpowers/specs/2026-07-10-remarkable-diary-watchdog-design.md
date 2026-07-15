# reMarkable diary — watchdog + auto-start (+ finger exit)

**Date:** 2026-07-10  
**Status:** ✅ Implemented (`diary.service` + install-service; boots into SebbyCorp Notepad shell)

## Goal

Make the takeover diary self-recovering so a freeze or reboot never requires an SSH
rescue again (the incident on 2026-07-07). The tablet becomes a **dedicated diary
device**: it boots straight into the diary and auto-restarts it on crash, with a
crash-loop guard. Add a **finger long-press** exit (leave without saving) alongside the
existing save-and-exit.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Boot behavior | **Dedicated device** — boots into the diary |
| Supervisor | **systemd** service (idiomatic; boot + restart + backoff for free) |
| Restart policy | **`Restart=on-failure`** — respects an intentional clean exit, restarts on crash |
| Exit to normal UI | **Two paths**: existing save-and-exit (top-left tap) **+ new finger long-press (no save)** |
| Exit input | **Finger** (capacitive touch, `event2`) — the diary currently reads pen only |

Key discovery driving the restart policy: the top-left **save** tap already calls
`exit_to_library()` — it saves the page as a PDF to the library, then kills rm2fb + starts
xochitl and sets `running=0` (clean exit). So there is already a clean exit to reMarkable;
the watchdog must not fight it. `Restart=on-failure` + clean `exit(0)` on both exit paths
solves this: crash → relaunch; user exit → stay out.

## Components

### On-device supervisor (new)
1. **`diary.service`** (`/etc/systemd/system/`):
   - `ExecStart=/home/root/diary-run.sh`
   - `Restart=on-failure`, `RestartSec=3`
   - `StartLimitIntervalSec=120`, `StartLimitBurst=5` — crash-loop guard: 5 failures in
     2 min → unit fails and stays down (avoids hammering rm2fb → panel corruption). Reboot
     or `systemctl reset-failed` + start to recover.
   - `WantedBy=multi-user.target`, `enabled` → boots into the diary.
2. **`diary-run.sh`** (supervised foreground entry):
   - `systemctl stop xochitl` + hard-kill leftover xochitl pids (the 2026-07-07 gotcha),
     verify stopped.
   - Start rm2fb **only if not already running** (`pidof rm2fb_server`) so a diary restart
     never re-kills rm2fb (repeated rm2fb kills corrupt the panel).
   - `exec env LD_PRELOAD=/opt/lib/librm2fb_client.so /home/root/diary` (diary is the main
     process systemd tracks).
3. **`install-service.sh`** — writes the unit, `daemon-reload`, `enable`. One command to
   (re)install (needed because the unit lives on the rootfs partition; a switch back to
   3.27 would require re-running it).
4. **`diary-start.sh` / `diary-stop.sh`** rewired: start = `systemctl start diary.service`;
   stop = `systemctl stop diary.service` (+ ensure xochitl if not coming back).

### On-device exits (both end in a clean `exit(0)` so the watchdog stays out)
- **Save-and-exit** (existing, unchanged): top-left tap → `exit_to_library()` (save PDF →
  restore xochitl → `running=0`).
- **No-save exit** (new): **finger long-press, bottom-left corner, ~2s** →
  `exit_to_ui()` — same restore as `exit_to_library` (detached: kill rm2fb, start xochitl)
  minus the save, then `running=0`.

### diary.c touch support (new)
- Open `/dev/input/event2` (capacitive touch) alongside the pen; poll both fds.
- Parse Type-B multitouch: `ABS_MT_SLOT`, `ABS_MT_TRACKING_ID` (>=0 down, -1 up),
  `ABS_MT_POSITION_X/Y`. Track slot-0 down time + position.
- If a touch is held **≥2s** within the bottom-left corner zone → `exit_to_ui()`.
- Touch is used ONLY for this gesture (a brief tap does nothing → no palm-rejection needed;
  pen still drives all drawing and the tap gestures).
- **Calibration:** touch coordinates/orientation differ from pen and screen. Ship a first
  build that logs raw `MT_POSITION_X/Y`; press the bottom-left corner once; read the log;
  set the corner zone in raw touch coordinates; redeploy. (~one extra deploy cycle.)

## Error handling / edge cases
- Crash-loop guard prevents the rm2fb-corruption death spiral (safe-stop after 5 fails).
- rm2fb reused across diary restarts (not re-killed) — avoids panel corruption.
- Clean exit (either path) returns `exit(0)` → `on-failure` does not relaunch.
- No network dependency at start — the diary opens fb/pen/touch/fonts locally; LLM calls
  only happen when the user writes, by which time Wi-Fi is up.

## Testing
- `kill <diary pid>` → systemd relaunches it within ~3s; **rm2fb stays up**.
- Save button → saves + returns to reMarkable; diary does **not** relaunch.
- Finger-hold bottom-left ≥2s → returns to reMarkable (no save); does **not** relaunch.
- `systemctl is-enabled diary.service` = enabled (boot).
- Crash-loop: force 5 quick failures → unit fails and stays down (no panel hammering).
- Real reboot test → boots into diary — only with the user's OK (disruptive).

## Out of scope (YAGNI)
- No launch-from-UI-without-SSH re-entry (reboot or `systemctl start` re-enters).
- No scroll/zoom or pagination for big maps (separate backlog item).
- No change to the LLM/agent paths.
