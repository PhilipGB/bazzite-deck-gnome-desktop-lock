# vlock-suspend

A small installer for GNOME sessions where the desktop's native lock screen is unavailable or ineffective.

It binds **Super+L** to this sequence:

```text
switch to a free virtual terminal
→ lock all virtual consoles with Fedora kbd vlock -a
→ suspend through systemd-logind
→ resume to the vlock password prompt
→ return to the existing GNOME session after authentication
```

The graphical session and its applications remain running. The project does not replace GNOME, start a second desktop session, or modify device wakeup settings.

## Status

Version: **2.2.0**

Tested on:

- Bazzite Deck GNOME
- Fedora 43 userspace
- OneXPlayer X1 Pro 3-in-1
- Wayland GNOME session
- `s2idle` suspend

This is intentionally Fedora/Bazzite-specific. The installer requires `vlock`, `openvt`, and `chvt` to come from Fedora's `kbd` package and rejects other implementations.

## Requirements

- Fedora or Bazzite with the `kbd` package
- GNOME with writable media-key settings
- systemd and systemd-logind
- `sudo` and `visudo`
- Python 3 with GObject/Gio bindings
- a local, active, non-remote GNOME session
- a physical keyboard for the vlock password prompt

The installer must be run as the logged-in desktop user from a terminal inside the GNOME session. Do not run the installer itself with `sudo`.

## Installation

Clone the repository, then run:

```bash
chmod +x ./install-vlock-suspend.sh
./install-vlock-suspend.sh install
```

The installer requests `sudo` only while installing root-owned files.

It creates:

```text
/usr/local/libexec/vlock-suspend
/etc/systemd/system/vlock-suspend-<UID>.service
/etc/sudoers.d/vlock-suspend-<UID>
~/.local/state/vlock-suspend/screensaver-binding.json
```

It also creates a GNOME custom shortcut at:

```text
/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vlock-suspend/
```

The existing GNOME lock binding is backed up before being disabled.

### Existing Super+L shortcuts

The installer refuses to overwrite an unrelated custom **Super+L** shortcut.

It can migrate recognized earlier `vlock-console` setups, including installations that use:

```text
~/.local/bin/vlock-console
~/.config/systemd/user/vlock-console.service
/usr/local/sbin/vlock-console-root
/usr/local/sbin/vlock-and-suspend-root
```

Legacy files are removed only after the replacement shortcut has been installed successfully.

## Usage

### Lock and suspend

Press:

```text
Super+L
```

Or start the service through the installer:

```bash
./install-vlock-suspend.sh test
```

Expected sequence:

```text
vlock console
→ suspend
→ resume to vlock
→ enter the user's normal Linux password
→ return to the existing GNOME session
```

There should be no graphical administrative-authentication dialog before the console lock appears.

### Check status

```bash
./install-vlock-suspend.sh status
```

A healthy installation resembles:

```text
Root helper:         installed
System unit file:    installed
Sudoers rule:        installed and authorized (start/stop)
Unit load state:     loaded
Unit active state:   inactive
Built-in binding:    @as []
Custom binding:      '<Super>l'
Custom command:      '/usr/bin/sudo -n /usr/bin/systemctl start --no-block vlock-suspend-1000.service'
```

Run `status` as the desktop user, not through `sudo`.

### Inspect logs

After testing and unlocking:

```bash
./install-vlock-suspend.sh logs
```

A successful suspend includes messages similar to:

```text
tty2 is active in VT_PROCESS mode; requesting suspend
Suspend request accepted by logind; waiting for vlock authentication
Observed suspend-clock growth: 5908 ms
```

The kernel section should also show:

```text
PM: suspend entry (s2idle)
PM: suspend exit
```

The helper compares `CLOCK_BOOTTIME` and `CLOCK_MONOTONIC` before and after the operation. Their difference grows only across a real suspend. A successful `systemctl suspend` request alone is not treated as proof that the machine slept.

## Emergency recovery

A physical keyboard is required at the vlock console. Touchscreen and controller on-screen keyboards are not available there.

When SSH access is available, a wedged operation can be stopped with:

```bash
./install-vlock-suspend.sh abort
```

The equivalent direct command is:

```bash
sudo -n systemctl stop vlock-suspend-$(id -u).service
```

The installer authorizes only two exact passwordless commands:

```text
systemctl start --no-block vlock-suspend-<UID>.service
systemctl stop vlock-suspend-<UID>.service
```

It does not grant passwordless access to arbitrary services or arbitrary `systemctl` operations.

A PAM account lockout at the vlock prompt may leave SSH recovery or a reboot as the only practical recovery path.

## Uninstallation

Unlock first and ensure the service is inactive, then run:

```bash
./install-vlock-suspend.sh uninstall
```

Uninstallation:

- restores the previous GNOME built-in lock binding;
- removes the managed custom shortcut;
- removes the user-specific system service and sudoers entry;
- removes the shared root helper when no other user-specific service references it;
- removes recognized legacy files;
- removes the saved state directory.

The uninstaller refuses to proceed while the lock-and-suspend service is active.

## Security model

The root helper performs several checks before suspending:

- confirms it is running as root;
- validates the target username and UID;
- requires an active local graphical session owned by that user;
- verifies the graphical session is on the currently active VT;
- prevents concurrent lock operations with `flock`;
- starts Fedora `kbd`'s `vlock -a` as the desktop user;
- verifies that a different VT became active and entered `VT_PROCESS` mode;
- refuses to suspend when readiness verification fails;
- confirms after unlock that a real suspend interval occurred.

`VT_PROCESS` is used as a readiness proxy for Fedora `kbd`'s `vlock -a`. It proves that a process has claimed the VT; by itself it does not describe how every possible VT owner handles release requests.

The helper also validates its launcher process group before sending group-directed termination signals.

## Suspend and wake limitations

This project controls locking and the suspend request. It deliberately does **not** alter hardware wakeup policy.

A machine may resume immediately because of:

- USB devices or docks;
- USB-C monitors and power-delivery renegotiation;
- PCIe PME events;
- network adapters;
- firmware or ACPI events.

Those problems are hardware-specific and should be diagnosed separately. Do not add a machine-specific `/sys/.../power/wakeup` workaround to the generic installer.

If the helper reports no real suspend interval, inspect:

```bash
./install-vlock-suspend.sh logs
```

Look for messages such as:

```text
Console-switch failed
No real suspend interval was detected
```

## Troubleshooting

### An administrative password dialog appears before locking

Version 2.2.0 uses a narrowly scoped sudoers rule rather than a polkit rule.

Check:

```bash
./install-vlock-suspend.sh status
```

The custom command should begin with:

```text
/usr/bin/sudo -n /usr/bin/systemctl start --no-block
```

An older shortcut that invokes `pkexec`, a legacy wrapper, or plain system-level `systemctl` can still trigger an authentication dialog. Rerun `install` from the active GNOME session to migrate recognized legacy setups.

### Super+L is already assigned

The installer protects unrelated shortcuts and exits rather than overwriting them. Remove or reassign the conflicting GNOME custom shortcut, then rerun installation.

### The system locks but does not suspend

Unlock, then inspect:

```bash
./install-vlock-suspend.sh logs
```

The service treats a suspend request as unconfirmed until the suspend-clock delta shows that monotonic time actually stopped.

### The system immediately wakes

This is usually a device or firmware wake source, not a vlock failure. The installer does not change wakeup configuration.

### Installation reports a missing GNOME schema

Run the installer inside the actual GNOME desktop session, not from a TTY, SSH shell, container, or root shell.

## Updating

Run the newer installer over the existing installation:

```bash
./install-vlock-suspend.sh install
```

Managed root files are replaced in place. The installer refuses to overwrite root-owned files that do not contain its management marker or a recognized earlier sudoers rule.

Do not update while the lock service or a recognized legacy lock service is active.

## Command reference

```text
install     Install or update the feature
uninstall   Remove it and restore the previous GNOME lock binding
status      Show installation and shortcut status
test        Start the installed lock-and-suspend service
abort       Stop a wedged service for SSH recovery
logs        Show service, helper, and kernel suspend logs
help        Show command help
```

## Scope

This project is suitable for a specific class of systems:

- GNOME is the active desktop;
- GNOME's native lock path is unavailable or nonfunctional;
- the system has Linux virtual terminals;
- Fedora's `kbd` implementation of `vlock -a` works correctly;
- suspend is provided by systemd-logind.

It is not a general cross-distribution screen locker.

## License

This project is licensed under the GNU General Public License,
version 3 or later. See [LICENSE](LICENSE).
