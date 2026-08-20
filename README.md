# sys_audit

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
