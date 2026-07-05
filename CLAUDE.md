# Halothane

A macOS menu-bar app (by **SFOLN LLC**) that supervises process memory and
pauses runaway processes before they destabilize the system. Born from an
incident where a bug in an ACP proxy made Zed grow to 100GB+ and triggered the
OS memory-panic UI. The name evokes an anesthetic — Halothane puts a runaway
process to sleep (SIGSTOP) rather than killing it.

> **Naming note:** everything is **Halothane** — project (`Halothane.xcodeproj`),
> scheme/target (`Halothane`), source folder (`Halothane/`), bundle
> (`com.sfoln.Halothane`), product (`Halothane.app`).

## What it does

- Samples every process's `phys_footprint` (the metric Activity Monitor's
  "Memory" column shows) a few times a second.
- **Warns** when a process exceeds a threshold or grows too fast.
- **Pauses** (SIGSTOP) a process — and its whole process tree — when configured
  to. Paused = frozen; it cannot allocate further. Auto-pause is **off by
  default** so legitimately heavy apps (LLM inference, VMs, big builds) aren't
  interrupted; you opt in globally or per-app.
- **Pause monitoring** (disarm) globally, with a duration (15m / 1h / 4h / until
  resumed). Disarming stops all warnings, auto-pauses, and pressure-coupling for
  the shared engine — i.e. for *every* account — and auto-re-arms when the timer
  elapses. Already-paused processes stay paused.
- Couples to kernel memory-pressure: on critical system pressure it pauses the
  largest non-exempt process.
- No auto-kill — Quit/Force-Kill are manual actions on an already-paused process.

## Architecture

One binary, two modes:

- **`Halothane`** (normal launch) — SwiftUI `MenuBarExtra` app (`LSUIElement`,
  no Dock icon). A thin UI over a `SupervisorBackend`.
- **`Halothane --daemon`** (launched by launchd as root) — headless supervisor.

```
Halothane.app (per-user UI, runs in each account)
  Monitor (ObservableObject)  ──uses──>  SupervisorBackend
                                           ├─ RemoteBackend  → XPC → root daemon   (preferred)
                                           └─ LocalBackend   → in-proc SupervisorCore (fallback, current user only)

launchd LaunchDaemon: Halothane --daemon (root)
  NSXPCListener (Mach service com.sfoln.Halothane.Helper, system domain)
  SupervisorCore  — sampling · growth · policy · actuator · pressure · disarm
  config: /Library/Application Support/Halothane/config.json

launchd LaunchAgent (com.sfoln.Halothane.GUI, /Library/LaunchAgents):
  starts the menu-bar UI for every GUI login session → both accounts get control.
```

The root daemon's Mach service lives in the system bootstrap namespace, so the
per-user UI connects to it from **any** login session — that's what makes
monitoring work across both fast-user-switched accounts.

### Key files (`Halothane/`)

| File | Role |
|------|------|
| `Entry.swift` | `@main` (`HalothaneEntry`); branches to daemon vs app on `--daemon` |
| `HalothaneApp.swift` | SwiftUI `App` + menu-bar label (captures `openWindow`) |
| `SupervisorCore.swift` | The engine (UI-free): timer loop, policy, actuator, pressure, disarm. Runs in-proc and in the daemon. |
| `ProcInfo.swift` | libproc wrappers: `phys_footprint`, ppid/uid, process tree |
| `Actuator.swift` | SIGSTOP/SIGCONT/SIGTERM/SIGKILL (whole tree) |
| `GrowthTracker.swift` | per-pid footprint history → growth rate |
| `MemoryPressure.swift` | kernel memory-pressure dispatch source |
| `PolicyEngine.swift` | pure warn/pause decision from a `ProcSample` + `ConfigData` |
| `ConfigData.swift` | value-type settings (engine + XPC wire format) |
| `Config.swift` | SwiftUI `@Published` settings, bridges to/from `ConfigData` |
| `Backend.swift` | `SupervisorBackend` protocol, `LocalBackend`, XPC protocols, Mach service name |
| `DaemonMain.swift` | root daemon: XPC listener, broadcasts snapshots, persists config |
| `DaemonClient.swift` | `RemoteBackend` XPC client |
| `ClientTrust.swift` | gates XPC callers to Halothane's designated requirement (team-OU pin) |
| `Monitor.swift` | UI view-model; owns a backend, posts notifications, menu-bar headline, disarm |
| `HUDController.swift` / `HUDView.swift` | floating always-on-top overlay (NSPanel) for warns/pauses |
| `Notifications.swift` | UN notification presentation delegate |
| `ProcessActions.swift` | shared action buttons (pause/resume/quit/kill/exempt) |
| `RuleEditor.swift` | per-app rule editor (exempt / per-field override) |
| `ProcessPickerField.swift` | process-name autocomplete combobox |
| `MenuContentView.swift` / `SettingsView.swift` / `ProcessesView.swift` | UI |
| `BrandColors.swift` | Halothane palette (teal/mint/ink/slate); teal is also AccentColor |
| `Models.swift` | `ProcSample`, `PausedProcess`, `Snapshot`, `SupervisorEvent`, … |
| `Assets.xcassets` | `AppIcon` (squircle H-monogram), `AccentColor` (brand teal) |

## Branding

Assets live in `branding/` (`logo.png`, `halothane-brand.png`). The app icon is
generated from `logo.png` (composited into a macOS squircle at the required
sizes). Brand: calm/clinical — teal-aqua vapor
swirl, charcoal "H", Inter type, palette teal `#45C5D6` / mint `#BFE9EC` / ink
`#2A2E32` / slate `#8A9296`. Semantic state colors (orange = warn, red = paused)
are intentionally outside the brand palette.

## Build

```sh
xcodebuild -project Halothane.xcodeproj -scheme Halothane -configuration Debug \
  -destination 'platform=macOS' build
# product: .../Build/Products/Debug/Halothane.app
```

The Xcode project uses the modern synchronized-folder format (objectVersion 77):
files added under `Halothane/` are picked up automatically — no `.pbxproj`
membership edits needed.

### Signing

- **Team: SFOLN LLC (`MXBM8H7F26`).** Building from source with your own team
  works too — set your team/identity in the project's Signing settings.
- Manual signing. App Sandbox **off**
  (required to signal other processes); Hardened Runtime **on**.
- `ClientTrust` pins XPC callers to `identifier "com.sfoln.Halothane" and anchor
  apple generic and certificate leaf[subject.OU] = "MXBM8H7F26"`. The OU pin
  holds across Apple Development (debug) and Developer ID (release) certs and
  across renewals — no change needed for notarization.

**Distribution:** `Scripts/build-pkg.sh` builds a Release, signs with
**Developer ID Application** + **Developer ID Installer**, notarizes, and
staples a distributable `.pkg`. MAS is not viable (sandbox + cross-user
control).

## Privileged daemon + GUI agent (install)

The daemon is the same app binary run with `--daemon`, installed as a system
LaunchDaemon; the GUI agent runs the menu-bar app per login session.

```sh
# full install: copy to /Applications + daemon + agent (covers all logged-in accounts)
sudo Scripts/install.sh /path/to/Halothane.app

# remove (resumes anything it had paused; removes daemon + agent)
sudo Scripts/uninstall-helper.sh

# verify
sudo launchctl print system/com.sfoln.Halothane.Helper | grep -E 'state|pid'
tail -f /var/log/halothane-helper.log
```

When the daemon is running, the menu header shows **"system-wide (all
accounts)"**; otherwise **"this user only"**.

## Testing the pause behavior

`/tmp/memballoon.c` (compile at `-O0` — at `-O2` the touch loop is dead-code
eliminated) is a throwaway memory hog. Add a per-app rule matching `memballoon`
with auto-pause and a low threshold, run it, and watch it get paused. Verify the
kernel stopped it with `ps -o pid,stat,comm` (state `T`).

## Conventions

- Memory is always `phys_footprint`, never raw RSS (RSS misses compressed pages
  — a holding process's RSS collapses while its footprint stays high).
- The engine is pure/UI-free so it behaves identically in-proc and in the
  daemon. Keep policy decisions in `PolicyEngine` and side effects in
  `SupervisorCore`.
- Thresholds default to **percent of physical RAM** (machine-relative);
  absolute GB is a toggle.
