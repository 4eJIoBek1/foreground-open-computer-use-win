## [2026-10-07 21:40] | Task: Fix Ensure-Foreground occlusion bug

### Execution Context
* **Agent ID**: opencode coding agent session
* **Base Model**: Muse Spark (via opencode)
* **Runtime**: Windows 10/11, PowerShell 5.1, portable Go 1.27.1

### User Query
> Fix the Ensure-Foreground bug found during dual-monitor click testing: clicks sometimes go to the wrong (overlapping) window, and `failed to bring app window to foreground` errors appear even though the window visibly rises. Sources are in this repo; commit straight to main; do not touch the release or opencode configs; build the exe but do not test the new version.

### Changes Overview
**Scope:** `apps/OpenComputerUseWindows` (runtime.ps1 + main.go), README, history.

**Key Actions:**
- **[Occlusion hit-test]**: new `Get-OccluderInfo` (`WindowFromPoint` + `GetAncestor(GA_ROOT)`); same-PID top-level windows are treated as own UI, not occluders.
- **[No silent mis-clicks]**: every mouse tool verifies the final point right before input; a covered point throws `inputBlockedByOccluder(x,y,occluderPid,occluderProcess,occluderWindow)` instead of clicking into the wrong window.
- **[Reliable raise]**: `Ensure-Foreground` retries 3x (150/300/600 ms), checks `SetWindowPos` return value, restores minimized windows only (`IsIconic` guard, maximized stay maximized), and bypasses the foreground lock via momentary `SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT=0)` restored in `finally` (no Alt-key trick).
- **[Occluder in JSON]**: PS error responses carry an `occluder {pid, process, windowTitle}` object; `main.go` parses it (`psResponse.Occluder`) and renders a human-readable MCP error naming the covering process.
- **[Keyboard tools]**: `type_text`/`press_key` keep PID-only focus semantics (`-KeysOnly`), unchanged hard-fail behavior.
- **[Docs]**: README `Ensure-Foreground` section synced with the new behavior.

### Design Intent (Why)
Foreground-PID match does not imply the click point is visible: a previous raise changes z-order without transferring foreground, so the next call early-returned `true` and the click landed on the overlapping window. Hit-testing the exact point plus lock-timeout bypass with retries fixes both the silent mis-click and the spurious `failed to bring app window to foreground` errors.

### Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main.go`
- `README.md`
- `docs/histories/2026-10/20261007-2140-ensure-foreground-occlusion-fix.md`

### Validation
- `go build` OK, `go vet` OK, PowerShell parser: 0 syntax errors.
- `go test`: only pre-existing failure `TestWindowsRuntimeForegroundActionsRequireOptIn` (fails on main before this change too: the fork runtime intentionally uses `SetFocus` unconditionally, the template test expects opt-in flags).
- No live run of the new binary (per user request); test battery (primary/secondary monitor clicks, deliberate occlusion) is left for the user.

### Follow-up fix (same task, 2026-10-08)
- Live testing showed every hit-test resolving to the desktop (`occluder=explorer`).
  Root cause: `WindowFromPoint(int x, int y)` P/Invoke is wrong on x64 — a by-value
  `POINT` struct travels in one register, two ints in two, so native code always
  read Y=0 (top screen edge). Verified empirically: struct-style declaration hits
  the right window, int-pair style always hits the desktop. Fixed by declaring
  `POINT` struct by value; all other P/Invokes in the file take scalars or
  pointers and are unaffected.
