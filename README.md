# sway-vnc-display-switcher

A Sway/Wayland remote desktop module using wayvnc. Handles display switching between a physical monitor and a headless virtual output, with automatic workspace migration on KVM switch, a waybar indicator, and a quake-style dropdown terminal.

All site-specific values (output names, positions, resolution, SSH host, keybindings) live in a single conf file. Nothing is hardcoded.

---

## Features

| Feature | Requires |
|---|---|
| wayvnc on headless virtual output with auto-restart | `wayvnc` |
| Automatic workspace migration on KVM switch (USB hub detection) | `udevadm` |
| Automatic workspace migration on monitor hotplug | `kanshi` |
| `vnc-serve kill` — fully destroy headless output (Steam compatibility) | `swaymsg` |
| Manual migration keybindings (`Super+Ctrl+D/N`) | `sway` |
| Waybar output indicator (teal = physical, orange = headless) | `waybar` |
| Rofi display menu (click indicator to switch output) | `waybar` + `rofi` |
| Quake-style dropdown terminal (`Ctrl+Shift+Space`) | configurable terminal |
| SSH tunnel helper for VNC clients | `ssh` |

---

## How it works

### Side-by-side outputs

Two compositor outputs are always present and always enabled:

- `HDMI-A-1` (or your monitor's name) — physical display, at compositor position `0,0`
- `HEADLESS-1` — permanent wlroots virtual output, at compositor position `2560,0` (your monitor's width)

Both outputs are always active. `ws-migrate` locks them to their correct positions on every call. Keeping outputs side-by-side (rather than overlapping) prevents cursor drift onto the wrong output.

wayvnc always captures one output at a time; `ws-migrate` switches the capture live via `wayvncctl output-set`.

### Scale factor and coordinate math

All compositor positions are in **logical pixels**, not physical pixels. This distinction matters when `HEADLESS_SCALE` is not 1.

**Example (this machine's conf):**

```
HEADLESS_RES="3456x2064"   # physical resolution of HEADLESS-1
HEADLESS_SCALE=2           # scale factor
```

Logical dimensions = physical ÷ scale:

```
3456 × 2064  at scale 2  →  logical 1728 × 1032
```

This means:

- `HEADLESS_POS` / `HEADLESS-1` appears at compositor position `(0, 0)` with logical size `1728×1032`
- `PHYSICAL_POS` / `HDMI-A-1` must be parked at `x=1728` (not 3456) — the logical width of HEADLESS-1
- The full compositor bounding box at scale 2 is `(0,0)–(1728+2560, 1440)` in logical pixels, `(0,0)–(4288,1440)`

The `map_to_output` cursor fix relies on this: wlroots maps the 3456×2064 VNC frame to HEADLESS-1's logical `1728×1032` space at scale 2, so VNC coordinates map cleanly 1:1 to logical HEADLESS-1 coordinates with no overflow into HDMI-A-1's logical space.

If `HEADLESS_SCALE=1` (default for most setups), logical = physical and the positions are straightforward. If you set a non-1 scale, always derive `HEADLESS_POS` from the logical width (`physical_width ÷ scale`), not the physical width.

### KVM switch detection

Most KVM switches preserve EDID and HPD. This means the monitor never truly disconnects at the DRM/kernel level, so Sway never fires output events on a KVM switch. kanshi does not help here.

`output-watcher` handles KVM detection via **USB hub udev events**. When the KVM switches away, its USB hub fires a `remove` event; when it switches back, an `add` event fires. `output-watcher` catches these and calls `ws-migrate` accordingly.

| USB event | Action |
|---|---|
| `remove` (KVM switched away) | `ws-migrate headless` |
| `add` (KVM switched back) | 1.5s delay (EDID settle) → `ws-migrate hdmi` |

The 1.5s delay is intentional — KVM switches cause a full HDMI reconnect at the EDID level; Sway needs time to initialize the output before mode changes stick.

For KVMs that _do_ drop EDID (true hotplug), `output-watcher` also subscribes to Sway output events as a fallback.

#### Finding your KVM's USB hub path

The hardest part of setup is identifying the correct value for `KVM_USB_HUB` in conf. This is a path suffix that uniquely identifies your KVM's built-in USB hub in the kernel device tree.

**Step 1 — watch raw udev events while switching:**

```bash
udevadm monitor --kernel --subsystem-match=usb
```

Switch the KVM away from this machine. You'll see a burst of events. Here's what a typical burst looks like:

```
KERNEL[...] remove   /devices/pci0000:00/0000:00:14.0/usb1/1-6/1-6.4/1-6.4.1/1-6.4.1:1.0 (usb)
KERNEL[...] remove   /devices/pci0000:00/0000:00:14.0/usb1/1-6/1-6.4/1-6.4.1            (usb)
KERNEL[...] remove   /devices/pci0000:00/0000:00:14.0/usb1/1-6/1-6.4/1-6.4.2/1-6.4.2:1.0 (usb)
KERNEL[...] remove   /devices/pci0000:00/0000:00:14.0/usb1/1-6/1-6.4/1-6.4.2            (usb)
KERNEL[...] remove   /devices/pci0000:00/0000:00:14.0/usb1/1-6/1-6.4                    (usb)
KERNEL[...] remove   /devices/pci0000:00/0000:00:14.0/usb1/1-6                           (usb)
```

Child devices (keyboard, mouse, USB ports on the KVM) fire first. The **hub itself** is the shortest path — it fires last on remove and first on add. You want the path to the hub, not its children.

**Step 2 — identify the hub line:**

The hub is the device whose path ends without a child suffix. In the example above, `1-6/1-6.4` is the KVM hub — everything above it (like `1-6.4.1`, `1-6.4.2`) is a device *attached to* the hub.

To confirm which device is the hub itself, check its class before switching:

```bash
# List all USB devices with their class
lsusb -t
# Or check sysfs directly — a hub has bDeviceClass=09
for d in /sys/bus/usb/devices/*/; do
    class=$(cat "$d/bDeviceClass" 2>/dev/null)
    [ "$class" = "09" ] && echo "$d"
done
```

**Step 3 — set KVM_USB_HUB:**

Take the last two path components of the hub line (everything after `.../usb1/`):

```
/devices/pci0000:00/.../usb1/1-6/1-6.4  →  KVM_USB_HUB="1-6/1-6.4"
```

If your KVM hub path has only one component (e.g. `/usb1/1-6`), use just that:

```
KVM_USB_HUB="1-6"
```

The value is matched as a path suffix: `output-watcher` looks for events where the path ends with `/$KVM_USB_HUB ` (with a trailing space before the subsystem label). This avoids matching child devices that start with the same prefix.

**Step 4 — verify with the startup check:**

`output-watcher` also checks the hub's presence at startup via `/sys/bus/usb/devices/$KVM_USB_HUB`. You can verify manually:

```bash
# KVM connected to this machine:
ls /sys/bus/usb/devices/1-6/1-6.4    # should exist

# KVM switched away:
ls /sys/bus/usb/devices/1-6/1-6.4    # should not exist (No such file or directory)
```

If both check out, your `KVM_USB_HUB` value is correct.

**Common issues:**

- **Multiple hubs fire on switch** — some KVMs have a two-level hub tree (a root hub with a port hub attached). Use the *port hub* path (the more specific/longer one), not the root hub. The root hub path stays in `/sys/bus/usb/devices/` even when the KVM is switched away; the port hub path disappears.
- **KVM path changes after reboot** — USB bus numbers can shift if other devices are added or removed. If detection stops working after hardware changes, re-run `udevadm monitor` and update `KVM_USB_HUB`.
- **No events at all** — some KVMs use separate USB controllers per port rather than a shared hub. In this case USB hub detection won't work; rely on the Sway output event fallback (EDID-dropping KVM) or trigger migration manually.

### output-watcher

`output-watcher` runs two event loops in parallel:

1. **USB watcher** — `udevadm monitor` on the USB subsystem; matches the KVM hub path from `KVM_USB_HUB` in conf
2. **Sway output watcher** — `swaymsg -t subscribe '["output"]'`; queries `get_outputs` on each event to detect active-state changes (for EDID-dropping KVMs)

Both watchers include debouncing to prevent transient output state changes (during `ws-migrate` reconfiguration) from triggering spurious counter-migrations.

The startup state check guards against migrating to headless when no headless output exists (e.g. after `vnc-serve kill`).

`output-watcher` is launched automatically by `sway-vnc-apply`'s generated `sway-vnc.conf` via `exec_always`.

### vnc-serve

`vnc-serve` is the main control script. It runs wayvnc in a loop, restarting on unexpected exits.

```bash
vnc-serve          # start wayvnc (auto-restarts on crash)
vnc-serve grab     # move all workspaces → headless output (full remote access)
vnc-serve release  # move all workspaces → physical output (desk use)
vnc-serve stop     # kill wayvnc and migrate workspaces back to physical output
vnc-serve kill     # stop everything, destroy headless output, kill daemons
```

### vnc-serve kill — full headless teardown

`vnc-serve kill` fully destroys the headless output for situations where apps (like Steam) misbehave when a second display is detected. It:

1. Stops wayvnc
2. Migrates all workspaces to the physical output (`ws-migrate hdmi`)
3. Kills `output-watcher` (via pgid file — prevents it from auto-migrating back)
4. Kills kanshi (prevents it from recreating the headless output)
5. Unplugs the headless output (`swaymsg output HEADLESS-N unplug`)
6. Removes the runtime state file

After `vnc-serve kill`, the headless output is completely gone from the compositor. Run `vnc-serve start` to recreate everything (headless output, kanshi, output-watcher, wayvnc).

**Important:** wlroots assigns monotonically incrementing names to headless outputs (`HEADLESS-1` → `HEADLESS-2` after unplug/create). The counter never resets except on a full sway restart. All scripts handle this via runtime headless name discovery (`svds_get_headless` in `_lib.sh`) — the conf file value is only used as a fallback.

### ws-migrate

`ws-migrate` is the canonical workspace migration tool. On every call it:

1. Locks both outputs to their correct positions (prevents compositor repositioning)
2. Sets workspace-to-output preferences (headless-first in headless mode, physical-first in hdmi mode)
3. Parks ws 99 on HDMI-A-1 in headless mode (satisfies sway's per-output workspace invariant without polluting ws 1–10)
4. Applies `map_to_output HEADLESS-1` to the wayvnc virtual pointer (see below)
5. Moves all workspaces 1–`WS_MAX` to the target output
6. Runs straggler sweep — re-anchors ws 99 on the parking output (making any auto-created straggler non-active so sway prunes it); scans all remaining non-ws-99 workspaces on the parking output (any number, not just 1–`WS_MAX`); moves each straggler to the target output; switches to `focused_num` after each move batch so moved empty workspaces are pruned on the target side. Repeats up to 2 times.
7. Restores focus to whichever workspace was active before the migration
8. Switches wayvnc capture via `wayvncctl output-set`
9. Refreshes the waybar indicator

```bash
ws-migrate hdmi      # → physical output
ws-migrate headless  # → headless output
```

Called by: `output-watcher`, kanshi profiles, Sway keybindings, waybar rofi menu, and `vnc-serve grab`/`release`.

### Sway per-output workspace invariant

Sway enforces a hard invariant: **every enabled output must have at least one visible workspace at all times.** If the last workspace is moved off an output, Sway immediately auto-creates a new empty workspace on it and (critically) steals focus to that output.

Preventing straggler workspaces and focus theft requires **two lines of defense**.

#### First line of defense: workspace 99 as a parking workspace

In headless mode, ws 99 is explicitly moved to HDMI-A-1 *before* any real workspaces are migrated. This satisfies Sway's invariant at migration start — HDMI-A-1 always has ws 99 — so Sway has no reason to auto-create anything immediately.

In hdmi mode, ws 99 is moved to HEADLESS-1 (it needs to live somewhere, and it's not actively used).

`sway-vnc-apply` emits `workspace 99 output HDMI-A-1 HEADLESS-1` in the generated `sway-vnc.conf` to establish the preference. `ws-migrate` parks it explicitly on every call regardless of preference.

Ws 99 is intentionally chosen to be far outside any normal workspace range. It is never navigated to during normal use.

#### Why ws 99 parking alone is not enough

During the main migration loop, `ws-migrate` runs `workspace number N` for each workspace being moved. This switches focus to ws N, **displacing ws 99 as the active workspace** on the parking output. Sway prunes ws 99 immediately — it is empty and no longer the active workspace.

When the **last** real workspace is finally moved off the parking output, the output becomes vacant → Sway auto-creates a new workspace there. This is the **straggler**. Its number is unpredictable: Sway picks the next available number, which can exceed `WS_MAX` (e.g. ws 11 when `WS_MAX=10`).

There are two failure modes if the straggler is not handled:

- **Straggler number ≤ WS_MAX:** a naive sweep finds and moves it to the target output, where it becomes the *active* workspace. Sway won't prune an active workspace, so the user lands on an empty workspace instead of their real one.
- **Straggler number > WS_MAX:** a sweep that only scans `1..WS_MAX` never sees it. It persists on the parking output permanently.

#### Second line of defense: the straggler sweep

After the main loop, `ws-migrate` runs a sweep:

1. **Re-anchor ws 99** on the parking output (`workspace number 99; move to $OTHER`). This displaces the straggler as the active workspace on the parking output → Sway prunes the straggler (empty + non-active).
2. **Expanded scan** — checks *all* non-ws-99 workspaces remaining on the parking output (not just `1..WS_MAX`), catching high-numbered auto-created workspaces.
3. **Move and restore** — moves any found straggler to the target output, then switches to `focused_num` (the user's original workspace). This makes the just-moved straggler non-active on the target side → Sway prunes it there too.
4. **Re-anchor ws 99** again to prepare for another sweep iteration.
5. Repeats up to 2 times.

After all sweep iterations, `ws-migrate` does a final `workspace number $focused_num` to ensure the user lands on their intended workspace regardless of how many sweep rounds ran.

Both lines of defense together make migration clean and focus-safe.

### Cursor confinement — `map_to_output`

**Problem:** When in headless/VNC mode, moving the VNC mouse to the right ~33% or bottom of the screen would cause windows to become non-interactive (clicks and scrolls stop working). The physical HDMI-A-1 desktop would activate silently.

**Root cause — two layers:**

1. **wlroots coordinate normalization.** wayvnc injects pointer events via the `zwlr_virtual_pointer_v1` protocol using `motion_absolute`. wlroots normalizes those coordinates against the *full compositor layout bounding box* — both outputs combined — not just HEADLESS-1's box. With HEADLESS-1 at `(0,0)` logical 1728×1032 and HDMI-A-1 at `(1728,0)` logical 2560×1440, the layout bounding box is 4288×1440. wayvnc sends physical pixel coordinates for a 3456×2064 VNC frame. At VNC x≈1393 (~40% across the VNC screen), the mapped logical x reaches 1728 — exactly the left edge of HDMI-A-1.

2. **Sway focus-follows-mouse.** The instant the cursor coordinate crosses into HDMI-A-1's logical coordinate space, `check_focus_follows_mouse()` fires `seat_set_focus()` — stealing focus to HDMI-A-1. All subsequent input events go to that output's workspaces.

**Fix:** `swaymsg "input '0:0:wlr_virtual_pointer_v1' map_to_output HEADLESS-1"`

This calls `wlr_cursor_map_input_to_output()` for the virtual pointer device. wlroots then normalizes `motion_absolute` coordinates against HEADLESS-1's bounding box alone (`0,0 → 1728×1032 logical`) instead of the full layout. The VNC frame (3456×2064 physical pixels) maps cleanly 1:1 to HEADLESS-1's logical space at scale 2. The cursor can never leave HEADLESS-1, so focus-follows-mouse never fires across outputs.

`ws-migrate headless` runs this command on every headless migration. If wayvnc restarts (crash recovery loop in `vnc-serve`), `ws-migrate headless` is called again automatically, re-applying the mapping to the new virtual pointer device. The `input_config` is also stored by sway keyed on the device identifier (`0:0:wlr_virtual_pointer_v1`), so sway will re-apply it automatically when wayvnc reconnects.

Note: `swaymsg -t get_inputs` does not expose a `mapped_to_output` field for virtual pointer devices — this is a cosmetic IPC omission. The mapping is functionally applied.

---

## Debugging

### Check compositor state

```bash
# Which outputs exist, their positions, scale, active state, current mode
swaymsg -t get_outputs

# Which workspaces exist and which output each is on
swaymsg -t get_workspaces

# Input devices (keyboard, pointer, virtual pointer)
swaymsg -t get_inputs
```

**Note on `get_inputs` and virtual pointers:** `swaymsg -t get_inputs` does not expose a `mapped_to_output` field for virtual pointer devices (`0:0:wlr_virtual_pointer_v1`). This is a cosmetic IPC omission — the mapping is functionally stored and applied by Sway. To verify the mapping is active, confirm you ran `ws-migrate headless` (which applies `map_to_output HEADLESS-1`) and test by moving the VNC cursor to an extreme corner; if it no longer activates HDMI-A-1, the mapping is working.

### Check daemon state

```bash
pgrep -a wayvnc          # is wayvnc running?
pgrep -a output-watcher  # is output-watcher running?
pgrep -a kanshi          # is kanshi running?
```

### wayvnc output state

```bash
wayvncctl output-list    # which outputs wayvnc knows about
wayvncctl output-set HEADLESS-1   # force capture to headless output
```

### Logs

```bash
# output-watcher event log — records every USB event, Sway output event, and migration call
cat ~/.local/state/sway-vnc/output-watcher.log
tail -f ~/.local/state/sway-vnc/output-watcher.log   # live follow
```

### Common diagnostic sequences

**VNC mouse stopped working / focus jumped to HDMI:**

```bash
ws-migrate headless   # reapplies map_to_output and re-parks ws 99
```

**Workspaces on wrong output:**

```bash
swaymsg -t get_workspaces   # see which output each workspace is on
ws-migrate hdmi             # or: ws-migrate headless
```

**Verify output positions are correct:**

```bash
swaymsg -t get_outputs | grep -E '"name"|"rect"'
# In headless mode expect: HEADLESS-1 at x=0, HDMI-A-1 at x=<HEADLESS logical width>
# In hdmi mode: positions may be reversed depending on PHYSICAL_POS/HEADLESS_POS in conf
```

**wayvnc capturing wrong output (blank VNC or wrong desktop visible):**

```bash
wayvncctl output-set HEADLESS-1
# If wayvnc is not running:
vnc-serve
```

---

## Quick install

```bash
./install.sh
```

The installer is interactive — it asks questions first, writes a conf file, then steps through each optional component. Nothing is installed without a `y` prompt. Config files (sway, waybar, kanshi) are never patched automatically; snippets are printed and optionally saved for you to merge.

### Prerequisites

```bash
# Arch / CachyOS
sudo pacman -S wayvnc kanshi waybar rofi
sudo systemctl enable --now sshd
# udevadm is part of systemd — already present on most systems
```

### Manual install (skip installer)

1. Copy `conf.example` to `~/.config/sway-vnc-display-switcher/conf` and edit it.
2. Copy `bin/` scripts to `~/.config/sway-vnc-display-switcher/bin/` and make them executable.
3. Copy `templates/kanshi.template` to `~/.config/sway-vnc-display-switcher/templates/kanshi.template`.
4. Add `~/.config/sway-vnc-display-switcher/bin` to your PATH (e.g. in `~/.zshenv`).
5. Add one include line to `~/.config/sway/config` (after removing any hardcoded workspace/dropdown/migration/exec_always sections):
   ```
   include ~/.config/sway/sway-vnc.conf
   ```
6. Run `sway-vnc-apply` to generate `sway-vnc.conf` and reload sway.
7. Merge snippets from `waybar/` into your waybar config.

---

## Configuration

All configuration lives in `~/.config/sway-vnc-display-switcher/conf`. The installer generates this file interactively. See `conf.example` for all available variables and their defaults.

Key variables:

| Variable | Default | Description |
|---|---|---|
| `PHYSICAL_OUTPUT` | `HDMI-A-1` | Your monitor's output name (`swaymsg -t get_outputs`) |
| `HEADLESS_OUTPUT` | `HEADLESS-1` | Virtual output name (wlroots default) |
| `PHYSICAL_POS` | `0 0` | Compositor position of physical output (x y) |
| `HEADLESS_POS` | `2560 0` | Compositor position of headless output — set to your monitor's width |
| `KVM_USB_HUB` | _(blank)_ | USB hub path suffix for KVM detection (see `udevadm monitor --kernel --subsystem-match=usb`) |
| `VNC_ADDR` | `127.0.0.1` | wayvnc bind address — keep localhost; use SSH tunnel to connect |
| `VNC_PORT` | `5900` | wayvnc port |
| `VNC_SSH_HOST` | `user@hostname` | SSH host for tunnel hint and `client/connect.sh` |
| `WAYBAR_SIGNAL` | `8` | Signal number for waybar refresh (`pkill -RTMIN+N waybar`) |
| `TERMINAL` | `kitty` | Terminal for dropdown (must support `--class`) |
| `MONITOR_DESC` | _(blank)_ | Your monitor's description for kanshi (`swaymsg -t get_outputs`) |
| `MONITOR_RES` | `2560x1440` | Physical monitor resolution |
| `HEADLESS_RES` | _(same as MONITOR_RES)_ | Headless virtual output resolution (can differ from physical) |
| `DROPDOWN_WIDTH` | `100ppt` | Dropdown terminal width |
| `DROPDOWN_HEIGHT` | `80ppt` | Dropdown terminal height |

To find your KVM's USB hub path:

```bash
udevadm monitor --kernel --subsystem-match=usb
# Switch the KVM — look for add/remove lines and note the path component after /devices/
# Example output:  KERNEL[...] remove   /devices/pci.../usb1/1-6/1-6.4 (usb)
# → set KVM_USB_HUB="1-6/1-6.4"
```

---

## Waybar indicator

The `custom/display` module shows the currently active output.

- **Teal** — workspaces are on the physical output
- **Orange** — workspaces are on the headless output (VNC mode)

Click to open a rofi menu listing all outputs. The active output is marked `✓ active`. Selecting an entry runs `ws-migrate` immediately.

Merge `waybar/config.snippet.jsonc` into your waybar config and `waybar/style.snippet.css` into your stylesheet. The installer handles placeholder substitution (`__WAYBAR_SIGNAL__`, etc.).

---

## Dropdown terminal

A quake-style scratchpad terminal toggled by `Ctrl+Shift+Space` (configurable).

- Uses `app_id=dropdown` — any terminal emulator that supports `--class` works.
- Output-agnostic: works identically on the physical output and over VNC.
- The `no_focus [app_id="dropdown"]` sway rule is required. Without it, the hidden scratchpad window steals keyboard focus on `swaymsg reload`, making the session appear frozen.

---

## Kanshi setup

kanshi handles physical monitor **hotplug** (true connect/disconnect events). It is not used for KVM switching — that is handled by `output-watcher`.

`kanshi-start` generates `~/.config/kanshi/config` from `templates/kanshi.template` on every sway start/reload, using values from conf. **Do not edit `~/.config/kanshi/config` directly** — it is overwritten each time. Edit the template instead:

```
~/.config/sway-vnc-display-switcher/templates/kanshi.template
```

The template uses two profiles:

- **docked** — physical monitor present; sets both outputs to side-by-side positions and migrates workspaces to the physical output
- **headless** — physical monitor absent (VNC-only mode); migrates workspaces to headless

`kanshi-start` is launched automatically by `sway-vnc-apply`'s generated `sway-vnc.conf` via `exec_always`. No manual sway config entry is needed.

---

## Client connection

### Any VNC client — SSH tunnel

```bash
# From your client machine:
./client/connect.sh user@yourserver

# Or manually:
ssh -fNL 5900:127.0.0.1:5900 user@yourserver
# Then connect your VNC client to localhost:5900
```

`client/connect.sh` reads `VNC_SSH_HOST` from conf, checks if the port is already forwarded, opens the tunnel, and prints VNC client connection strings.

Add `client/ssh_config.snippet` to your `~/.ssh/config` for a named shortcut:

```bash
ssh -fNL 5900:127.0.0.1:5900 svds
```

### macOS — Screens 5

Screens 5 handles the SSH tunnel natively:

- **Host:** `127.0.0.1` / **Port:** `5900`
- Enable SSH tunnel → set host to `user@yourserver`

---

## Key mapping over VNC (macOS)

Getting the Super key and clipboard working over VNC from a Mac requires two fixes: a custom XKB layout for the modifier key, and adjusted terminal bindings for copy/paste.

### The Super key problem

Sway's `$mod` is `Mod4` (Super). Over VNC from Screens 5 on macOS, the key you'd want to use as Super is the **right Option key** — macOS intercepts the left Option key for its own uses, but right Option passes through to Screens 5 freely.

The problem is the key translation chain:

```
Mac right Option key
  → Screens 5 sends VNC keysym: Meta_R
    → wayvnc looks up Meta_R in the XKB keymap → keycode <SUPR> (206)
      → in the stock "us" XKB layout, <SUPR> has NoSymbol at level 0
        → no modifier map entry → Sway never sees Mod4 → $mod bindings don't fire
```

The stock `us` layout simply doesn't assign anything to `<SUPR>` — it's a keycode that exists on PC keyboards with a dedicated Super key, but macOS keyboards don't have one so it goes unused. wayvnc's internal lookup for `Meta_R` lands on `<SUPR>`, finds nothing, and the modifier is lost.

### Debugging with wev

The way to see this happening is `wev` (Wayland event viewer):

```bash
# In your Sway session (or over VNC once the tunnel is up):
wev
```

Press the key in question. `wev` prints the raw keysym and modifier state arriving at the compositor. You'll see `Meta_R` arrive with a keycode of 206, but no modifier bit set — confirming it's not in Mod4.

To also inspect how XKB is interpreting keycodes:

```bash
xkbcli interactive-wayland
```

This shows the full XKB interpretation (level, symbol, modifiers) for each keypress. Pressing right Option over VNC would show `<SUPR>` resolving to `NoSymbol`.

### The fix: a custom XKB layout

Create `~/.config/xkb/symbols/mac_vnc`:

```xkb
default partial alphanumeric_keys modifier_keys
xkb_symbols "basic" {
    include "us"

    // <SUPR> (keycode 206) — receives Meta_R from Screens 5 via VNC
    // Assign Meta_R at level 0 so wayvnc lookup succeeds,
    // and map to Mod4 so Sway treats it as $mod (Super).
    key <SUPR> { [ Meta_R, Meta_R ] };
    modifier_map Mod4 { Meta_R };

    // <META> (keycode 205) — handle Meta_L the same way in case it arrives
    key <META> { [ Meta_L, Meta_L ] };
    modifier_map Mod4 { Meta_L };
};
```

libxkbcommon ≥ 1.0 searches `$XDG_CONFIG_HOME/xkb/` before the system paths, so no root access or system file modification is needed. The layout is picked up automatically.

Then tell wayvnc to use it in `~/.config/wayvnc/config`:

```ini
xkb_layout=mac_vnc
```

Verify the layout compiles cleanly:

```bash
xkbcli compile-keymap --layout mac_vnc
```

After restarting wayvnc, pressing right Option + 1 over VNC should switch to workspace 1.

### Ctrl+C / Ctrl+V don't work over VNC

Screens 5 sends clipboard copy/paste as raw ASCII control characters (`\x03`, `\x16`) rather than keysym sequences. wayvnc receives control characters that don't map to any XKB keysym, so they're dropped. This is a Screens 5 behavior, not a wayvnc bug.

**Workaround — use the system clipboard via right-click**, or rebind copy/paste in your terminal to use Alt instead of Ctrl.

For kitty, add to `~/.config/kitty/kitty.conf`:

```ini
# Over VNC, Ctrl+C/V don't pass through — use Alt instead
map alt+c  copy_to_clipboard
map alt+v  paste_from_clipboard
map alt+t  new_tab
map alt+left  previous_tab
map alt+right next_tab
map alt+1 goto_tab 1
map alt+2 goto_tab 2
map alt+3 goto_tab 3
map alt+4 goto_tab 4
map alt+5 goto_tab 5
```

From macOS, press **left Option + the key**. macOS passes left Option through to Screens 5 for non-intercepted combos, and these arrive as `Alt_L` keysyms which kitty sees cleanly.

Note: `map ctrl+c` / `map ctrl+v` still work in a local Sway session — the Alt bindings are additive, not replacements.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `WAYLAND_DISPLAY not set` | Run `vnc-serve` from inside your Sway session (not via SSH without a Wayland socket) |
| VNC connection refused | `pgrep -a wayvnc` — not running; run `vnc-serve` from the Sway session |
| Workspaces on wrong output after KVM switch | Check `output-watcher` is running (`pgrep -a output-watcher`); verify `KVM_USB_HUB` in conf matches your KVM's USB hub path |
| KVM switch not detected | Run `udevadm monitor --kernel --subsystem-match=usb` and switch the KVM — look for add/remove lines and update `KVM_USB_HUB` in conf |
| Focus lands on wrong output after migration | The straggler sweep in `ws-migrate` handles this. Run `ws-migrate hdmi` or `ws-migrate headless` to re-migrate. |
| Workspaces on wrong output (manual fix) | `ws-migrate hdmi` or `ws-migrate headless`, or use `Super+Ctrl+D/N` |
| HDMI resolution wrong after KVM switch | Wait ~2s (1.5s settle delay in ws-migrate). If still wrong: `swaymsg output HDMI-A-1 mode 2560x1440` |
| Cursor drifts to wrong output | `ws-migrate` locks output positions — run it to re-anchor. Also check `PHYSICAL_POS`/`HEADLESS_POS` in conf match your kanshi config |
| Mouse activates HDMI output over VNC / clicks stop working | `map_to_output` is not applied. Run `ws-migrate headless` to reapply. This happens when wayvnc starts before the first `ws-migrate headless` call. See "Cursor confinement" under How it works. |
| VNC not showing physical output when docked | `wayvncctl output-set HDMI-A-1` — wayvnc may have crashed and recovered pointing at the wrong output |
| kanshi "no profile matched" | HEADLESS-1 may not exist — run `swaymsg create_output` then `kanshictl reload` |
| Waybar icon missing | Check `~/.config/waybar/display.sh` is executable; run it manually to verify JSON output |
| Double cursor over VNC | Remove `--render-cursor` from your wayvnc invocation — it bakes the server cursor into the stream while the VNC client renders its own |
| Right Option key doesn't work as Super | Missing `mac_vnc` XKB layout or wayvnc not configured to use it — see "Key mapping over VNC" section |
| `$mod` bindings fire but right Option doesn't trigger them | `modifier_map Mod4 { Meta_R }` missing from XKB layout — verify with `xkbcli compile-keymap --layout mac_vnc` |
| Ctrl+C/V not working in terminal over VNC | Expected — Screens 5 sends raw ASCII control bytes, not keysyms. Use Alt+C/V in kitty (see kitty config) |

---

## File tree

```
sway-vnc-display-switcher/
├── conf.example                    # all configuration variables with defaults
├── install.sh                      # interactive installer
├── bin/
│   ├── _lib.sh                     # shared helpers: conf loading, headless discovery
│   ├── vnc-serve                   # wayvnc lifecycle manager (start/stop/grab/release/kill)
│   ├── ws-migrate                  # workspace migration tool
│   ├── output-watcher              # KVM/output event watcher
│   ├── dropdown.sh                 # quake-style dropdown terminal toggle
│   ├── kanshi-start                # generates kanshi config and starts kanshi
│   └── sway-vnc-apply              # generates sway-vnc.conf from conf and reloads sway
├── templates/
│   └── kanshi.template             # envsubst template for ~/.config/kanshi/config
├── waybar/
│   ├── display.sh                  # waybar module script (outputs JSON status)
│   ├── display-menu.sh             # rofi output selector (click handler)
│   ├── config.snippet.jsonc        # waybar config block to merge
│   └── style.snippet.css           # waybar CSS to merge
├── kanshi/
│   └── config.example              # reference kanshi profile (superseded by kanshi.template)
└── client/
    ├── connect.sh                  # SSH tunnel helper
    └── ssh_config.snippet          # ~/.ssh/config block for named tunnel shortcut
```
