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

## License

Not verified — please set this in the repo yourself (e.g. MIT), currently no license is included.# sys_audit

Bash-Skript, das einen strukturierten System-Snapshot (Hardware, Kernel, Pakete, Dienste, Fehler) als Textreport erzeugt — für Fehlerdiagnose, Forenposts und als Kontext für KI-gestützte Analyse der eigenen Software-/Hardware-Umgebung.

Unterstützt Arch, Debian/Ubuntu, Fedora und openSUSE über eine gemeinsame Codebasis (Distributionserkennung via `PKG_FAMILY`), Fallback `unknown` für alles andere.

## Verwendung

```bash
chmod +x sys_audit.sh
./sys_audit.sh              # Standard: alles drin
./sys_audit.sh --no-services
./sys_audit.sh --no-packages
./sys_audit.sh --minimal
./sys_audit.sh --help
```

Root-Rechte werden per `sudo`-Relaunch automatisch angefragt — nicht selbst mit `sudo` aufrufen. `--help` bricht sofort ab, ohne sudo anzufragen oder Daten zu sammeln.

## Flags

| Flag | Wirkung |
|---|---|
| `--no-services` | `[SYSTEMD]` + `[RECENT ERRORS]` weglassen |
| `--no-packages` | `[PACKAGE MANAGEMENT & AUR]` + `[FULL PACKAGE INVENTORY]` weglassen |
| `--minimal` | Kurzform für `--no-services --no-packages` |
| `-h`, `--help` | Hilfe anzeigen und beenden |

Beide Toggle-Gruppen sind unabhängig kombinierbar. Der Output-Dateiname spiegelt den gewählten Scope wider: `<distro-id>_<full\|minimal\|services-only\|packages-only>_<datum>_<uhrzeit>.txt` (z. B. `arch_full_2026_08_15_1430.txt`).

## Erfasste Bereiche (immer aktiv)

- CPU (Modell, Kerne/Threads, x86-64-Feature-Level via AVX-Flags)
- RAM (Gesamt/Verfügbar, DIMM-Belegung via `dmidecode`, EXPO/XMP-Erkennung)
- GPU: NVIDIA (inkl. `nvidia-smi`), Nouveau, AMDGPU, Intel i915 — für die drei offenen Treiber wird die Mesa-Userspace-Version distributionsspezifisch nachgeschlagen
- Mainboard & Storage (inkl. `smartctl`, maskierte Seriennummern)
- Monitore (Plasma 6 `kscreen-doctor`-Parser, ergänzt um EDID-Auslesung via `/sys/class/drm`, X11-Fallback via `xrandr`)
- Netzwerkinterfaces (IPs, MACs, ZeroTier-/Bridge-Namen redigiert), DNS-Server via `resolvectl`
- Sound- und Input-Geräte
- Swap
- Repository-Audit & glibc-Herkunft (inkl. CachyOS-znver4-Optimierungserkennung auf Arch)
- Kernel & Microcode (echter Installations-Check auf allen vier Distros, siehe unten)
- Diskbelegung mit Warnschwelle (≥90 %)
- Proton/Wine-Versionsinventar (Steam- und Paketebene, distro-übergreifend)

## Optional per Flag

- `--no-services`: Systemd Failed Units, laufende/alle Service-Units + vollständiges Unit-File-Inventar (OpenRC-Fallback via `rc-status`), journalctl/dmesg-Fehlerauszug (letzte 30 Einträge)
- `--no-packages`: AUR-Status + Flatpak-Runtimes, vollständige Paketliste je Distro

Die AUR-Abfrage (Netzwerk-Call gegen die AUR-RPC-API) wird bei `--no-packages`/`--minimal` gar nicht erst ausgeführt, statt nur die Ausgabe zu unterdrücken.

## Informationstiefe je Distribution

Der Report ist zu einem großen Teil distro-unabhängig identisch (CPU/RAM/GPU/Monitore/EDID/Netzwerk/Storage/SMART/Swap/Kernel-Version/Disk/Proton/Flatpak/Services/Journal/dmesg). Drei Punkte unterscheiden sich technisch begründet:

| Bereich | Arch | Debian | Fedora | openSUSE |
|---|---|---|---|---|
| Microcode-Status | echter Check (`amd-ucode`/`intel-ucode`) | echter Check (`amd64-microcode`/`intel-microcode`) | echter Check (`microcode_ctl`/`amd-ucode-firmware`) | echter Check (`ucode-intel`/`ucode-amd`) |
| Paketliste gruppiert nach | Repository | — (apt/dpkg kennt keine Repo-Zuordnung pro Paket) | Vendor | Vendor |
| glibc-Herkunft | tatsächlicher Repo-Name | N/A (technisch nicht ermittelbar via dpkg) | RPM-Vendor-Tag | RPM-Vendor-Tag |

Die fehlende Paketgruppierung und glibc-Herkunft auf Debian sind inhärente Grenzen von apt/dpkg (keine Repo-Zuordnung pro Paket ohne N+1 `apt-cache policy`-Abfragen) und werden im Report selbst als solche benannt, nicht verschwiegen. Die CachyOS-Optimierungserkennung ist bewusst Arch-exklusiv, da CachyOS nur dort existiert.

## Funktionsweise

Das Skript startet sich beim Aufruf ohne Root selbst per `exec sudo` neu, sammelt aber vorher Daten, die eine aktive User-Session voraussetzen (Desktop-Umgebung, `kscreen-doctor`, EDID-Zugriff über logind-ACLs, AUR-Helper wie `paru`/`yay`) und reicht sie über temporäre Dateien an den root-Kontext weiter. Alle Tempfiles werden über einen `EXIT`-Trap aufgeräumt.

Fehlerbehandlung läuft explizit über `${var:-default}`-Fallbacks statt `set -e` — das Skript ist bewusst auf Graceful Degradation ausgelegt: ein fehlendes Tool oder ein leerer Grep-Treffer führt zu `N/A`/`unknown` im Report, nicht zum Abbruch.

## Abhängigkeiten

Nicht alle Tools sind zwingend erforderlich — fehlende Befehle werden im Report als `unknown`/`N/A` markiert. Je nach System werden u. a. folgende externe Tools genutzt, sofern vorhanden:

`dmidecode`, `smartctl`, `lspci`, `lsblk`, `kscreen-doctor`, `edid-decode`, `xrandr`, `systemd-detect-virt`, `resolvectl`, `journalctl`, `dmesg`, `sha256sum`, `flatpak`, sowie distributionsabhängig `pacman`/`paru`/`yay` (Arch), `dpkg` (Debian/Ubuntu), `dnf`/`rpm` (Fedora), `zypper`/`rpm` (openSUSE) und `rc-status` (OpenRC-Init statt systemd).

## Datenschutz-Hinweise

Für die Weitergabe in öffentlichen Foren sind bereits einige Felder bewusst maskiert bzw. weggelassen:

- Hostname wird nicht im Klartext ausgegeben, nur als 8-stelliger SHA256-Kurzhash zur Selbstidentifikation über mehrere eigene Reports hinweg
- IPs, MAC-Adressen sowie ZeroTier-/Bridge-Interface-Namen werden redigiert
- Datenträger-Seriennummern werden maskiert (nur letzte 4 Zeichen sichtbar)

Trotzdem vor dem Teilen den Report einmal manuell durchsehen — der Default (alles an) gibt über die volle Paketliste und Dienstübersicht am meisten Systemdetails preis; bei Bedarf `--no-packages`, `--no-services` oder `--minimal` nutzen.

## Lizenz

Nicht verifiziert – bitte im Repo selbst festlegen (z. B. MIT), aktuell ist keine Lizenz hinterlegt.
