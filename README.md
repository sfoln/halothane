<p align="center">
  <img src="site/assets/logo.png" alt="Halothane" width="160">
</p>

# Halothane

**A macOS menu-bar app that freezes runaway processes before they take down your machine.**

Halothane was born from a real incident: a bug in an editor's agent proxy made it
grow past 100 GB of memory and trigger macOS's system-wide memory panic. The name
evokes an anesthetic — instead of killing a runaway process, Halothane puts it to
sleep (`SIGSTOP`), so you keep your unsaved work and decide its fate yourself.

## What it does

- Samples every process's `phys_footprint` (the same metric as Activity Monitor's
  "Memory" column) several times a second.
- **Warns** when a process crosses a memory threshold or grows too fast.
- **Pauses** (`SIGSTOP`) a process — and its whole process tree — when you've
  opted in. A paused process is frozen and cannot allocate another byte.
  Auto-pause is **off by default**, so legitimately heavy apps (LLM inference,
  VMs, big builds) aren't interrupted; you enable it globally or per-app.
- Couples to kernel **memory pressure**: at critical system pressure it pauses
  the largest non-exempt process instead of letting the machine grind to a halt.
- **Never auto-kills.** Quit / Force-Kill are manual actions you take on an
  already-frozen process.
- Works across **all logged-in accounts** (fast user switching included) via a
  single system-wide supervisor.

## Install

Get the signed, notarized installer at **[halothane.app](https://halothane.app)**
(one-time $19 purchase) and run it. The package installs the app to `/Applications`,
a privileged supervisor daemon, and a per-login menu-bar agent.

Prefer to build it yourself? The full source is here — see
[Build from source](#build-from-source). The paid build just saves you the
signing, notarization, and setup.

To uninstall (resumes anything Halothane had paused, removes daemon + agent):

```sh
git clone https://github.com/sfoln/halothane && sudo halothane/Scripts/uninstall-helper.sh
```

## Why it needs root (and why the source is public)

Pausing *any* user's runaway process — not just your own — requires a privileged
daemon. That's a serious ask, which is exactly why the whole codebase is
source-available: you can audit every line of what runs as root, or build and
install it yourself from source. The daemon is the same app binary run with
`--daemon`; there is no hidden component.

- The engine (`SupervisorCore`) is UI-free and side-effect-isolated: policy
  decisions live in `PolicyEngine`, signals in `Actuator`.
- The UI talks to the daemon over XPC; callers are verified against Halothane's
  code-signing requirement (`ClientTrust`).
- No network access, no telemetry, no auto-updates without your consent.

## Build from source

Requires Xcode on macOS 14+.

```sh
xcodebuild -project Halothane.xcodeproj -scheme Halothane \
  -configuration Release -destination 'platform=macOS' build

# install the daemon + menu-bar agent (self-explanatory, auditable scripts):
sudo Scripts/install.sh /path/to/Build/Products/Release/Halothane.app
```

Set your own development team in the project's Signing settings. App Sandbox is
off (required to signal other processes); Hardened Runtime is on.

## Architecture

One binary, two modes:

```
Halothane.app (per-user menu-bar UI, one per login session)
  Monitor ──uses──> SupervisorBackend
                      ├─ RemoteBackend → XPC → root daemon   (preferred)
                      └─ LocalBackend  → in-proc engine       (fallback, current user only)

launchd LaunchDaemon: Halothane --daemon (root)
  SupervisorCore — sampling · growth tracking · policy · actuator · pressure · disarm
```

See [CLAUDE.md](CLAUDE.md) for the full file-by-file map and engineering
conventions.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE) ©
2026 SFOLN LLC. You may read, run, modify, and share the source for any
**noncommercial** purpose; commercial use, resale, and commercial redistribution
require a commercial license from SFOLN LLC.

The Halothane name, logo, and app icon are trademarks of SFOLN LLC and are **not**
covered by that license — see [NOTICE](NOTICE).
