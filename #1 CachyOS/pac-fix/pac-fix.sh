#!/usr/bin/env bash
# pacfix.sh - Targeted package manager repair
# Scope: Eliminating download blockages and sync errors
# Version: 2.2 (robustified & corrected)

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Root check / sudo escalation (at the very beginning, before logging) ---
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# --- Logging only after obtaining root privileges ---
LOG_FILE="/tmp/pacfix_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Logging to $LOG_FILE"

# --- Lock check (Pacman + pacman-key) ---
LOCK="/var/lib/pacman/db.lck"
if [[ -f "$LOCK" ]]; then
    if pgrep -x pacman &>/dev/null || pgrep -x pacman-key &>/dev/null; then
        error "Pacman or pacman-key is actively running – lockfile will not be removed. Aborting."
        exit 1
    fi
    warn "Orphaned lockfile found. Removing $LOCK ..."
    rm -f "$LOCK"
fi

# --- Helper: Network check ---
check_network() {
    info "Checking network connectivity to a mirror ..."
    if ! curl -s --head --connect-timeout 5 https://mirror.cachyos.org/ >/dev/null; then
        warn "No connection to mirror – possible network issue."
        return 1
    fi
    return 0
}

# --- Step 1: Remove corrupt download fragments (corrected pattern) ---
info "[1/4] Removing corrupt download fragments..."
shopt -s nullglob
# Pacman typically uses *.part; additionally fallback to download-* just in case
fragments=(/var/cache/pacman/pkg/*.part /var/cache/pacman/pkg/download-*)
if (( ${#fragments[@]} > 0 )); then
    rm -rf "${fragments[@]}"
    info "  ${#fragments[@]} fragment(s) removed."
else
    info "  No fragments found."
fi
shopt -u nullglob

# --- Step 2: Mirror optimization (with preceding network check) ---
info "[2/4] Validating and optimizing mirror infrastructure..."

if ! check_network; then
    warn "Network unreachable – skipping mirror rating."
else
    if command -v cachyos-rate-mirrors &>/dev/null; then
        if timeout 240 cachyos-rate-mirrors; then
            info "  Mirror rating completed successfully."
        else
            exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                warn "  cachyos-rate-mirrors timed out after 240s – skipped."
            else
                warn "  cachyos-rate-mirrors failed (Exit $exit_code) – skipped."
            fi
        fi
    else
        warn "cachyos-rate-mirrors not found – mirror optimization skipped."
    fi
fi

# --- Step 3: Keyring reconstruction (only if needed) ---
info "[3/4] Reconstructing trust anchors (keyrings)..."

GNUPG_DIR="/etc/pacman.d/gnupg"
GNUPG_BAK="${GNUPG_DIR}.bak"

keyring_healthy() {
    if [[ ! -d "$GNUPG_DIR" ]]; then
        return 1
    fi
    pacman-key --list-keys &>/dev/null
}

# Keyring restore function – now with trap removal at the beginning to prevent double execution
keyring_restore() {
    trap - EXIT SIGINT SIGTERM   # prevents double execution
    error "Keyring reconstruction failed or was interrupted – restoring backup."
    if [[ -d "$GNUPG_BAK" ]]; then
        rm -rf "$GNUPG_DIR"
        cp -a "$GNUPG_BAK" "$GNUPG_DIR"
        warn "Backup restored. System state: unchanged."
    else
        error "No backup available – manual intervention required."
    fi
    error "Full log available at $LOG_FILE"
    exit 1
}

if keyring_healthy; then
    info "  Keyring is intact – skipping reconstruction."
else
    info "  Keyring corrupt or missing – performing reconstruction."

    # Safety checks
    if [[ -L "$GNUPG_DIR" ]]; then
        error "  $GNUPG_DIR is a symbolic link – aborting for security reasons."
        exit 1
    fi

    # Create backup
    if [[ -d "$GNUPG_DIR" ]]; then
        rm -rf "$GNUPG_BAK"
        cp -a "$GNUPG_DIR" "$GNUPG_BAK"
        info "  Keyring backup created: $GNUPG_BAK"
    fi

    # Set trap for interruptions
    trap keyring_restore EXIT SIGINT SIGTERM

    # Check network again (in case it wasn't checked before)
    if ! check_network; then
        error "Network unavailable – cannot update keyrings. Aborting."
        keyring_restore   # trap is disabled inside the function itself
    fi

    # Reset and rebuild
    rm -rf "$GNUPG_DIR"
    pacman-key --init
    pacman-key --populate archlinux cachyos

    # Install/update keyring packages (only if needed)
    # Sync the database first, but without performing a full upgrade
    pacman -Sy --noconfirm --needed archlinux-keyring cachyos-keyring

    # Verify after reconstruction
    if ! keyring_healthy; then
        error "Keyring is still defective after reconstruction."
        keyring_restore
    fi

    # Success – disable trap and delete backup
    trap - EXIT SIGINT SIGTERM
    rm -rf "$GNUPG_BAK"
    info "  Keyring successfully reconstructed."
fi

# --- Step 4: Full system update (NOW with -Syu, since the DB must always be up-to-date) ---
info "[4/4] Initiating full system synchronization..."
pacman -Syu --noconfirm

echo ""
echo -e "${GREEN}Integrity restored. System status: Nominal.${NC}"
info "Full log: $LOG_FILE"
