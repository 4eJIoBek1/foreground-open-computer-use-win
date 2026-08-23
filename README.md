# foreground-open-computer-use-win

**Windows-only fork** of [QwenLM/open-computer-use](https://github.com/QwenLM/open-computer-use) — foreground Computer Use with real cursor/keyboard input. **Tested only in [opencode](https://opencode.ai).**

> Unlike upstream, this build does **not** require Node.js — just run the `.exe` directly. The PowerShell runtime is embedded into the binary via `//go:embed` (`apps/OpenComputerUseWindows/main.go:22`).

Download the latest binary from **Releases**: `open-computer-use.exe` (Windows x64, Go 1.22+, no dependencies).

---

## How it differs from upstream `QwenLM/open-computer-use`

This fork patches only two source files: `apps/OpenComputerUseWindows/main.go` and `apps/OpenComputerUseWindows/runtime.ps1` (based on `@qwen-code/open-computer-use` v0.2.3). UIA **reading** (element tree, snapshots, `get_app_state`) is untouched.

### Core change: synthetic `PostMessage` → real system input

Upstream `runtime.ps1` sends mouse/keyboard via `PostMessage` (`WM_MOUSEMOVE`/`WM_LBUTTONDOWN`/`WM_KEYDOWN`/`WM_CHAR` directly into the window queue). The real cursor never moves and the OS input system is bypassed — apps that hit-test via `GetCursorPos` (Paint ribbon, WPF, etc.) ignore such clicks. Chromium also advertises `ScrollPattern` but silently ignores `Scroll()` calls, so upstream scroll in Chrome did not work.

**Patched runtime** uses real hardware input:

| Component | Upstream | This fork |
|---|---|---|
| `OCUWin32` class (C# P/Invoke) | `PostMessage`, `SendMessage`, `ScreenToClient`, `POINT` | `SetCursorPos`, `mouse_event`, `keybd_event`, `SendInput` + structs `MOUSEINPUT`/`KEYBDINPUT`/`InputUnion`/`INPUT` + `GetForegroundWindow`, `GetWindowThreadProcessId`, `GetCurrentThreadId`, `AttachThreadInput`, `SetForegroundWindow`, `SetFocus`, `ShowWindow`, `SetWindowPos`, `IsHungAppWindow` |
| `Send-MouseClick` | `PostMessage WM_MOUSEMOVE/DOWN/UP` | `SetCursorPos` + `mouse_event` (down `0x0002`/`0x0008`/`0x0020`, up `0x0004`/`0x0010`/`0x0040`, pauses 40/50ms) |
| `Send-Drag` | `PostMessage` left-only | `SetCursorPos` → `mouse_event DOWN` → 12 interpolated steps (20ms) → `mouse_event UP` — button from `mouse_button` param |
| `Send-Scroll` | `PostMessage WM_MOUSEWHEEL/HWHEEL` | `SetCursorPos` + `mouse_event(WHEEL 0x0800 / HWHEEL 0x1000, delta ±120×pages)` |
| `Send-Key` | `PostMessage WM_KEYDOWN/UP` | `keybd_event` down/up (`KEYEVENTF_KEYUP=0x0002`) with modifiers |
| `Send-Text` | `PostMessage WM_CHAR` per char | `SendInput` with `INPUT_KEYBOARD` type=1 + `KEYEVENTF_UNICODE=0x0004` (`[uint16]$code` — `[ushort]` does not exist in PS 5.1) |

### Tool handlers — always direct input (no UIA pattern fallback)

| Tool | Upstream (UIA-first) | This fork |
|---|---|---|
| `click` | `Invoke-PreferredClick` (Invoke/SelectionItem/Toggle) → fallback | Always `Send-MouseClick` at coordinates |
| `scroll` | `Invoke-Scroll` (ScrollPattern) → fallback | Always `Send-Scroll` (real wheel) — fixes Chrome |
| `type_text` | `Invoke-TypeText` (EditHandle/ValuePattern) → fallback | Always `Send-Text` (`SendInput` UNICODE) |
| `perform_secondary_action` | `Invoke-SecondaryAction` | Always `Send-MouseClick` on element coords |
| `set_value` | `ValuePattern.SetValue` | Click + `Ctrl+A` + `Send-Text` |
| `drag` | left-only | `Send-Drag` with `mouse_button` (left/right/middle) |
| `press_key` | `PostMessage` | `keybd_event` |

Removed dead code: `Invoke-PreferredClick`, `Invoke-Scroll`, `Invoke-TypeText`, `Invoke-SecondaryAction`, `Find-TextEntryElement`, `Get-NativeWindowHandle`, `Send-TextToEditHandle`, plus unused P/Invokes.

### `main.go` — drag now supports mouse button

`service.drag` signature extended: `drag(app, from_x, from_y, to_x, to_y, mouseButton string)` (`apps/OpenComputerUseWindows/main.go:316`). `psRequest.MouseButton` is populated from `mouse_button` arg (default `left`, enum `left`/`right`/`middle`). JSON schema for `drag` updated accordingly (`main.go:549`).

### `Ensure-Foreground` — bring target window to front before every action

Real clicks require the target window to be foreground (otherwise they hit the window on top).

```powershell
ShowWindow(SW_RESTORE=9)  # if minimized
→ AttachThreadInput(myThread, fgThread) # bypass foreground lock, no Alt-key trick
→ SetWindowPos(TOPMOST, SWP_NOMOVE|SWP_NOSIZE)
→ SetWindowPos(NOTOPMOST, SWP_NOMOVE|SWP_NOSIZE)
→ SetForegroundWindow + SetFocus → detach → verify by PID (not handle)
```

Prevents hanging on hung windows via `IsHungAppWindow`. On `type_text`/`press_key` it hard-fails if focus cannot be obtained (text would go to wrong window). After raising, window rect is re-read and click/drag points are recalculated.

### Side effects

* Moves the real cursor; target window must be visible (not background-capable).
* Agent sees only a single window (not the full screen).
* Screenshot/tree via UIA still works for `get_app_state`.

---

## No Node.js required — run the exe directly

Upstream distributes via npm and requires Node.js. This fork embeds `runtime.ps1` — the exe is self-contained (Go stdlib only).

Example `opencode.jsonc` (from the author's setup):

```json
"mcp": {
  "open-computer-use": {
    "type": "local",
    "command": [
      "C:\\Users\\User\\Desktop\\node-v24.18.0-win-x64\\open-computer-use.cmd",
      "mcp"
    ],
    "enabled": false
  },
  "foreground-open-computer-use": {
    "type": "local",
    "command": [
      "C:\\Users\\User\\Desktop\\node-v24.18.0-win-x64\\ocu-foreground\\open-computer-use.exe",
      "mcp"
    ],
    "enabled": false
  }
}
```

Replace the path with where you downloaded the release binary, e.g.:

```json
"foreground-open-computer-use": {
  "type": "local",
  "command": ["C:\\Tools\\open-computer-use.exe", "mcp"]
}
```

---

## Quick start (Windows)

1. Download `open-computer-use.exe` from [Releases](https://github.com/4eJIoBek1/foreground-open-computer-use-win/releases).
2. Add to your MCP config as above (`command`: path to exe, `args`: `["mcp"]`).
3. In opencode, enable `foreground-open-computer-use` and call `get_app_state` before actions.

CLI also works standalone:

```bash
open-computer-use.exe mcp
open-computer-use.exe list-apps
open-computer-use.exe snapshot "Notepad"
open-computer-use.exe call click --args '{"app":"Notepad","x":100,"y":100}'
```

## Building from source

Requires Go 1.22+ (stdlib only, `runtime.ps1` embedded).

```powershell
cd apps/OpenComputerUseWindows
go build -o open-computer-use.exe .
.\open-computer-use.exe mcp
```

## Platform support

* **Windows only** — tested only in **opencode** on Windows 10/11 with PowerShell 5.1.
* macOS/Linux runtimes from upstream are not included in this fork's release artifact (sources remain in repo).

## Credits

Fork of [QwenLM/open-computer-use](https://github.com/QwenLM/open-computer-use) (itself a fork of `iFurySt/open-codex-computer-use`). See `PATCH.md` logic and `apps/OpenComputerUseWindows/main.go` / `runtime.ps1` for full diff.
