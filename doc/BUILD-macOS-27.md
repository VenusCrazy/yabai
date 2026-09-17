# Building yabai for macOS 27.0 (Apple Silicon)

This guide walks through building, signing, installing and running this fork on
**macOS 27.0 (Apple Silicon / arm64)**. It is not limited to developers: if you
just want a working yabai on macOS 27, follow it top to bottom.

## What this fork changes

Two things differ from upstream `asmvik/yabai`:

1. **macOS 27 scripting-addition offsets** (`src/osax/arm64_payload.m`,
   `src/osax/common.h`, `src/osax/payload.m`).
   The scripting-addition (SA) locates private Dock/SkyLight symbols by fixed
   offsets. macOS 27 moved several of them, so upstream's offsets fail to
   resolve and space operations (`space --create`, `--destroy`, `--move`, …)
   break. This fork adds the macOS 27 offsets:

   | Symbol | macOS 27 offset |
   |-:|:-|
   | `dock.spaces` | `0x30000` (shared with macOS 26) |
   | `dppm` (DesktopPictureManager) | `0x40000` |
   | `fix_animation` | `0x200000` |
   | `add_space` | `0x200000` |
   | `remove_space` | `0x150000` |
   | `move_space` | `0x150000` |
   | `set_front_window` | `0x10000` (shared with macOS 26) |

   `OSAX_ATTRIB_SET_WINDOW` is intentionally no longer part of
   `OSAX_ATTRIB_ALL` (its only caller is disabled), so the SA still validates
   even though the `setFrontWindow` hook is not located on macOS 27.

2. **Scripting-addition load fix** (`src/sa.m`).
   Upstream refuses to inject the SA on arm64 unless the boot-arg
   `-arm64e_preview_abi` is present. That boot-arg is only needed for the
   `thread_convert_thread_state()` injection path used before macOS 14.4, and
   macOS 26+ refuses to set it at all ([#2741][issue-2741]). This fork only
   requires it on macOS < 14.4, which makes `yabai --load-sa` work again on
   26/27.

## Prerequisites

- macOS 27.0 on Apple Silicon.
- Xcode Command Line Tools:
  ```
  xcode-select --install
  ```
- **System Integrity Protection partially disabled** — both *Filesystem
  Protections* and *Debugging Restrictions* must be off for the SA to inject
  into Dock.app. Boot into Recovery and run:
  ```
  csrutil enable --without fs --without debug
  ```
  (or configure the equivalent custom configuration). Verify with `csrutil status`.
- Optional but recommended: a self-signed code-signing certificate named
  **`yabai-cert`** (see [Signing](#3-sign-the-binary)). Using it keeps the
  binary's designated requirement stable, so the Accessibility grant survives
  rebuilds. Create it once via *Keychain Access → Certificate Assistant →
  Create a Certificate…* (name: `yabai-cert`, type: *Code Signing*).

## 1. Clone the repository

```
git clone https://github.com/VenusCrazy/yabai.git
cd yabai
```

## 2. Build

```
make install
```

This compiles both the CLI/daemon and the arm64e SA payload/loader, and writes
the result to `bin/yabai`. Confirm it:

```
./bin/yabai --version
```

## 3. Sign the binary

```
codesign --force --sign "yabai-cert" bin/yabai
```

If you did not create a certificate, sign ad-hoc instead — but note that the
Accessibility grant must then be re-added after every rebuild:

```
codesign --force --sign - bin/yabai
```

## 4. Install

Install to a stable location that Homebrew cannot overwrite, e.g.
`/usr/local/bin`:

```
sudo install -m 755 bin/yabai /usr/local/bin/yabai
sudo codesign --force --sign "yabai-cert" /usr/local/bin/yabai   # optional re-sign
```

If Homebrew's yabai is installed it will shadow this build in `$PATH`
(`/opt/homebrew/bin` precedes `/usr/local/bin`). Remove it:

```
brew uninstall yabai
```

## 5. Register the launchd service

```
/usr/local/bin/yabai --stop-service        # if an old service exists
/usr/local/bin/yabai --uninstall-service   # if an old plist exists
/usr/local/bin/yabai --start-service
```

The generated `~/Library/LaunchAgents/com.asmvik.yabai.plist` will point at
`/usr/local/bin/yabai`. Checking `launchctl print gui/$(id -u)/com.asmvik.yabai`
should show `state = running`.

## 6. Grant Accessibility

yabai aborts with `could not access accessibility features!` until it is
granted. Open *System Settings → Privacy & Security → Accessibility*, remove
any stale entry, click **+**, press **Cmd+Shift+G**, enter
`/usr/local/bin/yabai` and enable it. Then restart the service:

```
/usr/local/bin/yabai --restart-service
```

## 7. Scripting-addition

### 7.1 First-time install

```
sudo /usr/local/bin/yabai --load-sa
```

This installs the SA (`/Library/ScriptingAdditions/yabai.osax`, version 2.1.31)
and injects the payload into Dock.app. On success a socket appears at
`/tmp/yabai-sa_<user>.socket`.

### 7.2 Keep it loaded across logins and Dock restarts

On macOS 27, Dock does **not** automatically load the SA, so it has to be
re-injected after every login and whenever Dock restarts. The standard yabai
approach is a signal plus a passwordless sudo rule:

Add a sudoers rule (validate before installing):

```
echo "$(id -un) ALL=(root) NOPASSWD: /usr/local/bin/yabai --load-sa" | sudo tee /tmp/yabai-sudoers
sudo visudo -cf /tmp/yabai-sudoers && sudo install -m 440 -o root -g wheel /tmp/yabai-sudoers /private/etc/sudoers.d/yabai
```

Add these lines near the top of `~/.config/yabai/yabairc` (before any window
rules are configured):

```
yabai -m signal --add event=dock_did_restart action="sudo /usr/local/bin/yabai --load-sa"
sudo /usr/local/bin/yabai --load-sa
```

The signal re-injects the SA whenever Dock restarts, and the direct call
covers login (the service sources `yabairc` at startup).

## 8. Verify

```
yabai -m query --spaces          # should list your spaces
yabai -m space --create          # exercises the add_space SA hook
yabai -m space <n> --destroy     # exercises the remove_space SA hook
```

If `--create` succeeds, the macOS 27 offsets are resolving correctly. The
payload also logs each resolved hook address:

```
sudo log show --last 2m --info --predicate 'eventMessage CONTAINS "yabai-sa"'
```

Look for `dock.spaces found at address …`, `addSpace found at address …`, etc.
`failed to get pointer to setFrontWindow function..` is expected and harmless
(see [What this fork changes](#what-this-fork-changes)).

## 9. Rebuilding after changes

`scripts/deploy.sh` automates build → sign → install → reload:

```
scripts/deploy.sh                 # uses /usr/local/bin and yabai-cert
scripts/deploy.sh ~/.local/bin    # custom install directory
```

It falls back to ad-hoc signing (with a warning) when `yabai-cert` is missing.

## Troubleshooting

| Symptom | Cause / fix |
|:-|:-|
| `missing required nvram boot-arg '-arm64e_preview_abi'` | You are running an upstream or older build. Use this fork's binary (the check is scoped to macOS < 14.4 here). |
| `could not access accessibility features! abort..` | Grant Accessibility to the exact installed path (`/usr/local/bin/yabai`) and restart the service. |
| `cannot create/destroy space due to an error with the scripting-addition` | The SA is not injected. Run `sudo /usr/local/bin/yabai --load-sa` and check `/tmp/yabai-sa_<user>.socket`. |
| SA stops working after Dock restarts | Ensure the `dock_did_restart` signal and the sudoers rule from §7.2 are in place. |
| `yabai: service file … already installed!` | Run `yabai --uninstall-service` before `--install-service`, or simply use `--start-service`. |
| `sudo: a password is required` in `/tmp/yabai_<user>.err.log` | The passwordless sudoers rule for `--load-sa` is missing or its path is wrong. |

Logs:

- service: `/tmp/yabai_<user>.out.log` and `/tmp/yabai_<user>.err.log`
- scripting-addition: `sudo log show --last 2m --info --predicate 'eventMessage CONTAINS "yabai-sa"'`

[issue-2741]: https://github.com/asmvik/yabai/issues/2741
