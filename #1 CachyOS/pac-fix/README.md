# pacfix.sh

Targeted repair script for the Pacman package manager on CachyOS/Arch. Fixes download blockages, sync errors, and broken keyrings without unnecessary side actions.

**Version:** 2.2 (robustified & corrected)

## What the script does

Runs in four steps, in this order:

1. **Fragment cleanup** – removes aborted downloads (`*.part`, `download-*`) from `/var/cache/pacman/pkg/`.
2. **Mirror optimization** – checks network connectivity to `mirror.cachyos.org`, then runs `cachyos-rate-mirrors` with a 240s timeout if reachable (skipped if no network or the tool isn't present).
3. **Keyring reconstruction** – only if the keyring (`pacman-key --list-keys`) is actually broken. If broken: backup to `/etc/pacman.d/gnupg.bak`, then `--init` → `--populate archlinux cachyos` → reinstall `archlinux-keyring` and `cachyos-keyring` via `pacman -Sy`. On failure or interruption (trap on EXIT/SIGINT/SIGTERM), automatic restore from backup.
4. **Full system sync** – `pacman -Syu --noconfirm`.

## Requirements

- Arch-based system with Pacman (tested in a CachyOS context)
- `sudo` privileges (script self-escalates via `exec sudo`)
- `curl` for the network check
- Optional: `cachyos-rate-mirrors` (step 2 is skipped otherwise)

## Usage

```bash
chmod +x pacfix.sh
./pacfix.sh
```

Root privileges are requested automatically via `sudo`. A manual `sudo` call isn't necessary, but doesn't hurt either.

## Logging

Every run writes a full log to:

```
/tmp/pacfix_<YYYYMMDD_HHMMSS>.log
```

The path is printed at start and end.

## Safety mechanisms

- **Lock check:** removes `/var/lib/pacman/db.lck` only if no `pacman` or `pacman-key` process is running; aborts otherwise.
- **Symlink protection:** aborts if `/etc/pacman.d/gnupg` is a symbolic link.
- **Keyring backup with trap:** if reconstruction fails, the original state is restored from backup (`trap keyring_restore EXIT SIGINT SIGTERM`).
- **No keyring intervention if healthy:** step 3 is skipped entirely if `pacman-key --list-keys` succeeds.

## What the script does not do

- No downgrades or package rollbacks
- No changes to `pacman.conf` or mirrorlist content (only `cachyos-rate-mirrors`, if present)
- No preventive action when no problem was detected (e.g. intact keyring, no fragments)

## Exit behavior

Runs with `set -euo pipefail` – aborts immediately on any unexpected error. Critical failures (network down during keyring reconstruction, keyring still broken after rebuild) explicitly trigger `keyring_restore` and `exit 1`.