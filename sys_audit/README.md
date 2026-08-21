# sys_audit

Bash script that produces a structured system snapshot (hardware, kernel, packages, services, errors) as a text report — for troubleshooting, forum posts, and as context for AI-assisted analysis of your own software/hardware environment.

Supports Arch, Debian/Ubuntu, Fedora, and openSUSE from a single codebase (distro detection via `PKG_FAMILY`), with an `unknown` fallback for anything else.

## Usage

```bash
chmod +x sys_audit.sh
./sys_audit.sh              # default: everything included
./sys_audit.sh --no-services
./sys_audit.sh --no-packages
./sys_audit.sh --minimal
./sys_audit.sh --help
```

Root is requested automatically via a `sudo` relaunch — don't invoke it with `sudo` yourself. `--help` exits immediately, without requesting sudo or collecting any data.

## Flags

| Flag | Effect |
|---|---|
| `--no-services` | omit `[SYSTEMD]` + `[RECENT ERRORS]` |
| `--no-packages` | omit `[PACKAGE MANAGEMENT & AUR]` + `[FULL PACKAGE INVENTORY]` |
| `--minimal` | shortcut for `--no-services --no-packages` |
| `-h`, `--help` | show help and exit |

Both toggle groups can be combined independently. The output filename reflects the chosen scope: `<distro-id>_<full\|minimal\|services-only\|packages-only>_<date>_<time>.txt` (e.g. `arch_full_2026_08_15_1430.txt`).

## Always collected

- CPU (model, cores/threads, x86-64 feature level via AVX flags)
- RAM (total/available, DIMM population via `dmidecode`, EXPO/XMP detection)
- GPU: NVIDIA (incl. `nvidia-smi`), Nouveau, AMDGPU, Intel i915 — for the three open-source drivers the Mesa userspace version is looked up per distro
- Motherboard & storage (incl. `smartctl`, masked serial numbers)
- Monitors (Plasma 6 `kscreen-doctor` parser, augmented with EDID readout via `/sys/class/drm`, X11 fallback via `xrandr`)
- Network interfaces (IPs, MACs, ZeroTier/bridge names redacted), DNS servers via `resolvectl`
- Sound and input devices
- Swap
- Repository audit & glibc origin (incl. CachyOS znver4 optimization detection on Arch)
- Kernel & microcode (real install check on all four distros, see below)
- Disk usage with a warning threshold (≥90%)
- Proton/Wine version inventory (Steam and package level, cross-distro)

## Optional per flag

- `--no-services`: systemd failed units, running/all service units + full unit-file inventory (OpenRC fallback via `rc-status`), journalctl/dmesg error excerpt (last 30 entries)
- `--no-packages`: AUR status + Flatpak runtimes, full package list per distro

The AUR query (a network call against the AUR RPC API) is skipped entirely under `--no-packages`/`--minimal`, rather than just suppressing its output.

## Information depth per distro

Most of the report is identical regardless of distro (CPU/RAM/GPU/monitors/EDID/network/storage/SMART/swap/kernel version/disk/Proton/Flatpak/services/journal/dmesg). Three areas differ for technical reasons:

| Area | Arch | Debian | Fedora | openSUSE |
|---|---|---|---|---|
| Microcode status | real check (`amd-ucode`/`intel-ucode`) | real check (`amd64-microcode`/`intel-microcode`) | real check (`microcode_ctl`/`amd-ucode-firmware`) | real check (`ucode-intel`/`ucode-amd`) |
| Package list grouped by | repository | — (apt/dpkg has no per-package repo tagging) | vendor | vendor |
| glibc origin | actual repo name | N/A (not determinable via dpkg) | RPM vendor tag | RPM vendor tag |

The missing package grouping and glibc origin on Debian are inherent limits of apt/dpkg (no per-package repo tagging without N+1 `apt-cache policy` queries), and the report itself states this rather than staying silent about it. CachyOS optimization detection is deliberately Arch-only, since CachyOS only exists there.

## How it works

The script re-execs itself under `exec sudo` when run without root, but collects data beforehand that requires an active user session (desktop environment, `kscreen-doctor`, EDID access via logind ACLs, AUR helpers like `paru`/`yay`) and passes it to the root context via temp files. All temp files are cleaned up via an `EXIT` trap.

Error handling runs explicitly through `${var:-default}` fallbacks instead of `set -e` — the script is deliberately built for graceful degradation: a missing tool or an empty grep match results in `N/A`/`unknown` in the report, not a script abort.

## Dependencies

Not all tools are strictly required — missing commands show up as `unknown`/`N/A` in the report. Depending on the system, the following external tools are used where available:

`dmidecode`, `smartctl`, `lspci`, `lsblk`, `kscreen-doctor`, `edid-decode`, `xrandr`, `systemd-detect-virt`, `resolvectl`, `journalctl`, `dmesg`, `sha256sum`, `flatpak`, plus, depending on distro, `pacman`/`paru`/`yay` (Arch), `dpkg` (Debian/Ubuntu), `dnf`/`rpm` (Fedora), `zypper`/`rpm` (openSUSE), and `rc-status` (OpenRC instead of systemd).

## Privacy notes

For sharing in public forums, some fields are already deliberately masked or omitted:

- Hostname is never printed in plaintext, only as an 8-character SHA256 short hash to recognize the same host across multiple reports of your own
- IPs, MAC addresses, and ZeroTier/bridge interface names are redacted
- Storage serial numbers are masked (only the last 4 characters shown)

Still, review the report manually before sharing it — the default (everything on) exposes the most system detail via the full package list and service overview; use `--no-packages`, `--no-services`, or `--minimal` if needed.
