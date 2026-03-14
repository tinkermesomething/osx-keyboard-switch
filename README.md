# OSX-keyboard-switch

Automatically switches macOS keyboard input layout when a non-Apple USB keyboard is connected or disconnected.

## What it does

- Non-Apple USB keyboard connected → switches to the PC layout (e.g. `British-PC`)
- All non-Apple USB keyboards disconnected → switches back to the Mac layout (e.g. `British`)
- Apple keyboards (built-in or external) are ignored
- Layouts are auto-detected from your enabled input sources — works for any region

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- Both your Mac and PC keyboard layouts enabled in **System Settings > Keyboard > Input Sources**

## How layout switching works

The daemon can't distinguish a real keyboard receiver from a combo receiver (e.g. a Logitech mouse dongle that also presents a phantom keyboard HID interface) purely from USB metadata — they look identical at the protocol level.

**First time only**: plug in your keyboard and press any key. The daemon learns the vendor+product ID, saves it to `~/.config/keyboard-switch/known-keyboards.json`, and switches immediately. Every subsequent plug-in is instant — no keypress needed.

## Install

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

The script compiles the Swift source, installs the binary to `~/.local/bin/keyboard-switch`, and registers it as a user LaunchAgent that starts at login.

### Input Monitoring permission (first install only)

macOS requires explicit permission for processes that monitor HID keyboard devices.

After running `install.sh`, go to:

> **System Settings > Privacy & Security > Input Monitoring**

Add `~/.local/bin/keyboard-switch`. Use **Cmd+Shift+G** in the file picker to navigate to hidden paths.

The daemon will log an error and the layout won't switch until this is granted. If you reinstall (replacing the binary), macOS will revoke the permission and you'll need to re-add it.

## Uninstall

```bash
./uninstall.sh
```

## Configuration

Layouts are auto-detected from your enabled input sources. If auto-detection doesn't work for your setup (e.g. non-standard layout names, or multiple PC layouts enabled), you can configure them explicitly.

### Finding your layout IDs

```bash
keyboard-switch --list-layouts
```

This prints all currently enabled keyboard layout IDs, e.g.:

```
com.apple.keylayout.British
com.apple.keylayout.British-PC
```

### Setting layouts manually

Create `~/.config/keyboard-switch/config.json`:

```json
{
  "macLayout": "com.apple.keylayout.British",
  "pcLayout":  "com.apple.keylayout.British-PC"
}
```

Both fields are optional. Any field present overrides auto-detection. Restart the daemon after changing config:

```bash
launchctl kickstart -k "gui/$(id -u)/com.local.keyboard-switch"
```

## Logs

```bash
tail -f ~/Library/Logs/keyboard-switch.log
```

## How it works

The daemon uses `IOHIDManager` (IOKit) to watch for USB HID device attach/detach and input events:

- Transport: USB, Vendor ID ≠ `0x05AC` (Apple), HID usage page 1 / usage 6 (keyboard)
- Input callbacks on HID usage page 7 (Keyboard/Keypad) identify which connected device is a real keyboard via actual keystrokes
- Once learned, vendor+product IDs are persisted to `~/.config/keyboard-switch/known-keyboards.json`
- Layout switching uses `TISSelectInputSource` (Carbon framework)

## Updating

Re-run `./install.sh` — it recompiles and restarts the agent. Re-grant Input Monitoring permission afterwards.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Layout doesn't switch | Check Input Monitoring permission |
| Plugged in keyboard, no switch | Press any key — first-time learning required |
| `Layout not found` in logs | Ensure both layouts are enabled in System Settings > Keyboard > Input Sources |
| `Auto-detect failed` in logs | Run `--list-layouts` and set layouts manually in `config.json` |
| Agent not running after reboot | Check `launchctl list com.local.keyboard-switch` |
| Permission revoked after update | Re-add binary in System Settings > Privacy & Security > Input Monitoring |
