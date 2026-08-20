#!/usr/bin/env bash
# System-audit report generator. Run --help for flags.
set -uo pipefail

trap '[ -n "${tmp_mon:-}" ]    && rm -f "$tmp_mon"
      [ -n "${tmp_aur:-}" ]    && rm -f "$tmp_aur"
      [ -n "${tmp_env:-}" ]    && rm -f "$tmp_env"
      [ -n "${tmp_edid:-}" ]   && rm -f "$tmp_edid"
      [ -n "${tmp_xrandr:-}" ] && rm -f "$tmp_xrandr"
      [ -n "${tmp_report:-}" ] && rm -f "$tmp_report"' EXIT
trap 'echo "Error: script interrupted" >&2; exit 130' INT TERM

script=$(realpath "$0")

for arg in "$@"; do
    [ "$arg" = "-h" ] || [ "$arg" = "--help" ] || continue
    cat <<'EOF'
Usage: sys_audit.sh [OPTIONS]

  --no-services    omit [SYSTEMD] + [RECENT ERRORS]
  --no-packages    omit [PACKAGE MANAGEMENT & AUR] + [FULL PACKAGE INVENTORY]
  --minimal        shortcut for --no-services --no-packages
  -h, --help       show this help and exit

Requests root via sudo automatically - do not run with sudo directly.
EOF
    exit 0
done

if [ "$EUID" -ne 0 ]; then
    # kscreen-doctor / EDID / AUR helpers all need the active user session -
    # none of this is available anymore once we've re-execed under sudo below.
    tmp_mon=$(mktemp /tmp/sys_audit_monitors.XXXXXX)
    tmp_aur=$(mktemp /tmp/sys_audit_aur.XXXXXX)
    tmp_env=$(mktemp /tmp/sys_audit_env.XXXXXX)
    tmp_edid=$(mktemp /tmp/sys_audit_edid.XXXXXX)
    tmp_xrandr=$(mktemp /tmp/sys_audit_xrandr.XXXXXX)

    {
        printf 'XDG_CURRENT_DESKTOP=%s\n' "${XDG_CURRENT_DESKTOP:-unknown}"
        printf 'XDG_SESSION_DESKTOP=%s\n' "${XDG_SESSION_DESKTOP:-unknown}"
        printf 'XDG_SESSION_TYPE=%s\n'    "${XDG_SESSION_TYPE:-unknown}"
        printf 'SHELL_USER=%s\n'          "${SHELL:-unknown}"
    } > "$tmp_env"

    if command -v edid-decode >/dev/null 2>&1; then
        shopt -s nullglob
        {
            for edid in /sys/class/drm/*/edid; do
                # sysfs reports size 0 via stat() for this attribute even when
                # readable data exists - skip the usual [ -s ] check, just try.
                conn=$(basename "$(dirname "$edid")")
                conn=${conn#card[0-9]-}
                decoded=$(edid-decode "$edid" 2>/dev/null)
                [ -z "$decoded" ] && continue
                printf '===CONN:%s===\n%s\n' "$conn" "$decoded"
            done
        } > "$tmp_edid"
        shopt -u nullglob
    fi

    if command -v kscreen-doctor >/dev/null 2>&1; then
        wd="${WAYLAND_DISPLAY:-}"
        if [ -z "$wd" ]; then
            for sock in wayland-0 wayland-1; do
                [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$sock" ] && wd="$sock" && break
            done
        fi
        [ -n "$wd" ] && WAYLAND_DISPLAY="$wd" kscreen-doctor -o 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' > "$tmp_mon"
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "x11" ] && command -v xrandr >/dev/null 2>&1; then
        DISPLAY="${DISPLAY:-:0}" xrandr --query 2>/dev/null > "$tmp_xrandr"
    fi

    # --no-packages/--minimal skip this: paru -Qu hits the AUR RPC over the
    # network and there's no point paying for it if it won't be printed.
    skip_aur=0
    for preflag in "$@"; do
        case "$preflag" in
            --no-packages|--minimal) skip_aur=1 ;;
        esac
    done

    helper_bin=""
    if [ "$skip_aur" -eq 0 ]; then
        if command -v paru >/dev/null 2>&1; then
            helper_bin="paru"
        elif command -v yay >/dev/null 2>&1; then
            helper_bin="yay"
        fi
    fi

    if [ -n "$helper_bin" ]; then
        {
            printf 'HELPER=%s\nUPDATES_START\n' "$helper_bin"
            "$helper_bin" -Qu 2>/dev/null || true
            printf 'UPDATES_END\nFOREIGN_START\n'
            "$helper_bin" -Qm 2>/dev/null || true
            printf 'FOREIGN_END\n'
        } > "$tmp_aur"
    else
        printf 'HELPER=none\n' > "$tmp_aur"
    fi

    sudo -v || { echo "Error: sudo authentication required." >&2; exit 1; }
    exec sudo /usr/bin/env bash "$script" \
        --monitor-tmpfile "$tmp_mon" --aur-tmpfile "$tmp_aur" --env-tmpfile "$tmp_env" \
        --edid-tmpfile "$tmp_edid" --xrandr-tmpfile "$tmp_xrandr" "$@"
fi

tmp_mon="" tmp_aur="" tmp_env="" tmp_edid="" tmp_xrandr=""
inc_svc=1
inc_pkg=1

while [ $# -gt 0 ]; do
    case "$1" in
        --monitor-tmpfile) tmp_mon="$2"; shift 2 ;;
        --aur-tmpfile)     tmp_aur="$2"; shift 2 ;;
        --env-tmpfile)     tmp_env="$2"; shift 2 ;;
        --edid-tmpfile)    tmp_edid="$2"; shift 2 ;;
        --xrandr-tmpfile)  tmp_xrandr="$2"; shift 2 ;;
        --no-services)     inc_svc=0; shift ;;
        --no-packages)     inc_pkg=0; shift ;;
        --minimal)         inc_svc=0; inc_pkg=0; shift ;;
        *) shift ;;
    esac
done

caller="${SUDO_USER:-${USER:-root}}"

distro_id=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
distro_id="${distro_id:-unknown}"
distro_pretty=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
distro_pretty="${distro_pretty:-unknown}"

date_tag=$(date '+%Y_%m_%d')
time_tag=$(date '+%H%M')
if   [ "$inc_svc" -eq 1 ] && [ "$inc_pkg" -eq 1 ]; then scope_tag="full"
elif [ "$inc_svc" -eq 0 ] && [ "$inc_pkg" -eq 0 ]; then scope_tag="minimal"
elif [ "$inc_svc" -eq 1 ]; then scope_tag="services-only"
else scope_tag="packages-only"
fi
out="${distro_id}_${scope_tag}_${date_tag}_${time_tag}.txt"
ts=$(date '+%Y-%m-%d %H:%M:%S')

if command -v pacman >/dev/null 2>&1; then
    pkg_family="arch"
elif command -v dpkg >/dev/null 2>&1; then
    pkg_family="debian"
elif command -v dnf >/dev/null 2>&1; then
    pkg_family="fedora"
elif command -v zypper >/dev/null 2>&1 || command -v rpm >/dev/null 2>&1; then
    pkg_family="suse_rpm"
else
    pkg_family="unknown"
fi

# Hostname never appears in plaintext (report gets shared publicly) - only
# a short hash so the same host can be recognized across multiple reports.
host_raw=$(hostname 2>/dev/null || echo unknown)
if command -v sha256sum >/dev/null 2>&1; then
    host_tag=$(printf '%s' "$host_raw" | sha256sum | cut -c1-8)
else
    host_tag="n/a"
fi

if [ -d /run/systemd/system ]; then
    init_sys="systemd"
elif command -v openrc >/dev/null 2>&1 || [ -d /run/openrc ]; then
    init_sys="OpenRC"
elif [ -f /sbin/init ] && /sbin/init --version 2>/dev/null | grep -qi upstart; then
    init_sys="Upstart"
else
    init_sys="unknown/other (PID1: $(cat /proc/1/comm 2>/dev/null || echo '?'))"
fi

if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt=$(systemd-detect-virt 2>/dev/null || true)
    virt="${virt:-unknown}"
    [ "$virt" = "none" ] && virt="none (bare metal)"
else
    virt="unknown (systemd-detect-virt not available)"
fi

xdg_de="unknown" xdg_sess_de="unknown" xdg_sess_kind="unknown" def_shell="unknown"
if [ -n "$tmp_env" ] && [ -s "$tmp_env" ]; then
    xdg_de=$(grep '^XDG_CURRENT_DESKTOP=' "$tmp_env" | cut -d= -f2-)
    xdg_sess_de=$(grep '^XDG_SESSION_DESKTOP=' "$tmp_env" | cut -d= -f2-)
    xdg_sess_kind=$(grep '^XDG_SESSION_TYPE=' "$tmp_env" | cut -d= -f2-)
    def_shell=$(grep '^SHELL_USER=' "$tmp_env" | cut -d= -f2-)
fi

# --- CPU ---
cpu_full=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -n1 | cut -d: -f2 | xargs || true)
cpu_full="${cpu_full:-unknown}"
cpu_cores=$(grep 'cpu cores' /proc/cpuinfo 2>/dev/null | head -n1 | awk -F': ' '{print $2}')
cpu_cores="${cpu_cores:-?}"
cpu_threads=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?')

cpu_flags=$(grep '^flags' /proc/cpuinfo 2>/dev/null | head -n1 || true)
if echo "$cpu_flags" | grep -qw avx512f  && echo "$cpu_flags" | grep -qw avx512cd \
   && echo "$cpu_flags" | grep -qw avx512bw && echo "$cpu_flags" | grep -qw avx512dq \
   && echo "$cpu_flags" | grep -qw avx512vl; then
    arch_lvl="x86-64-v4 (AVX-512: f+cd+bw+dq+vl active)"
elif echo "$cpu_flags" | grep -qw avx2; then
    arch_lvl="x86-64-v3 (AVX2 active)"
elif echo "$cpu_flags" | grep -qw sse4_2; then
    arch_lvl="x86-64-v2 (SSE4.2 active)"
else
    arch_lvl="x86-64-v1 (baseline)"
fi

# --- RAM ---
ram_total=$(awk '/^MemTotal:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo unknown)
ram_avail=$(awk '/^MemAvailable:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo unknown)

# State machine over dmidecode's "Memory Device" text blocks; skips empty slots.
ram_dimms=$(dmidecode -t memory 2>/dev/null | awk '
    /^Memory Device$/ { in_dev=1; size=""; speed=""; type=""; loc="" }
    in_dev && /^\tSize:/ { if ($2 == "No") next; size=$2" "$3 }
    in_dev && /^\tConfigured Memory Speed:/ { speed=$4" "$5 }
    in_dev && /^\tType:/ && !/Type Detail/ { type=$2 }
    in_dev && /^\tLocator:/ && !/Bank/ { loc=$2 }
    in_dev && /^$/ { if (size != "") printf "  - %-12s %s  %s  %s\n", loc, size, type, speed; in_dev=0 }
' || true)
ram_dimms="${ram_dimms:-  (no DIMM data)}"

# EXPO/XMP heuristic: configured speed exceeding the DIMM's rated max implies an OC profile.
ram_xmp=$(dmidecode -t memory 2>/dev/null | awk '
    /^Memory Device$/ { max=""; cfg="" }
    /^\tSpeed:/ && !/Configured/ { max=$2 }
    /^\tConfigured Memory Speed:/ { cfg=$4 }
    /^$/ { if (max != "" && cfg != "" && cfg > max) print "  EXPO/XMP active: Configured " cfg " MT/s > Rated " max " MT/s" }
' | head -n1 || true)
ram_xmp="${ram_xmp:-  EXPO/XMP: not detected (running at rated speed or dmidecode insufficient)}"

# --- GPU ---
gpu_models=$(/usr/bin/lspci 2>/dev/null | grep -E 'VGA|3D Controller' | sed 's/^.*: //' || true)
gpu_models="${gpu_models:-(none detected)}"

gpu_drv=$(/usr/bin/lspci -k 2>/dev/null \
    | awk '/VGA|3D Controller/{found=1} found && /Kernel driver in use:/{print $NF; found=0}' \
    | head -n1 | xargs || true)

gpu_type="Unknown" gpu_ver="N/A" gpu_vram="unknown"

# mesa is the shared userspace piece behind every open-source DRM driver
# (nouveau/amdgpu/i915) - same query, distro-specific package name.
mesa_ver() {
    case "$pkg_family" in
        arch)             pacman -Q mesa 2>/dev/null | awk '{print "mesa " $2}' ;;
        debian)           dpkg-query -W -f='mesa ${Version}' libgl1-mesa-dri 2>/dev/null ;;
        fedora|suse_rpm)  rpm -q --qf 'mesa %{VERSION}-%{RELEASE}' mesa-dri-drivers 2>/dev/null ;;
    esac
}

if grep -q 'Open Kernel Module' /proc/driver/nvidia/version 2>/dev/null; then
    gpu_type="NVIDIA Open-Kernel (proprietary user-space)"
    gpu_ver=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -n1)
    gpu_ver="${gpu_ver:-N/A}"
    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | awk '{printf "%.0f MiB", $1}' | head -n1)
        gpu_vram="${gpu_vram:-unknown}"
    fi
elif [ -d /proc/driver/nvidia/ ]; then
    gpu_type="NVIDIA proprietary (legacy/closed)"
    gpu_ver=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -n1)
    gpu_ver="${gpu_ver:-$(modinfo -F version nvidia 2>/dev/null || echo N/A)}"
    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | awk '{printf "%.0f MiB", $1}' | head -n1)
        gpu_vram="${gpu_vram:-unknown}"
    fi
elif lsmod 2>/dev/null | grep -q '^nouveau'; then
    gpu_type="Nouveau (open source)"
    gpu_ver="$(mesa_ver)"
    gpu_ver="${gpu_ver:-N/A}"
elif lsmod 2>/dev/null | grep -q '^amdgpu'; then
    gpu_type="AMDGPU (open source)"
    # amdgpu has no version string of its own worth reporting; mesa (userspace) is
    # the actual moving part and maps to what the NVIDIA driver package means above.
    gpu_ver="$(mesa_ver)"
    gpu_ver="${gpu_ver:-N/A}"
    vram_path=$(grep -rl amdgpu /sys/class/drm/card*/device/driver/module/drivers 2>/dev/null \
        | head -n1 | sed 's|/driver/module/drivers.*||' || true)
    [ -z "$vram_path" ] && vram_path=$(ls /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null \
        | head -n1 | sed 's|/mem_info_vram_total||' || true)
    if [ -n "$vram_path" ] && [ -f "${vram_path}/mem_info_vram_total" ]; then
        gpu_vram=$(awk '{printf "%.0f MiB", $1/1024/1024}' "${vram_path}/mem_info_vram_total" 2>/dev/null || echo unknown)
    fi
elif lsmod 2>/dev/null | grep -q '^i915'; then
    gpu_type="Intel i915 (open source)"
    gpu_ver="$(mesa_ver)"
    gpu_ver="${gpu_ver:-N/A}"
else
    gpu_type="Generic / Other (${gpu_drv:-unknown})"
    [ -n "$gpu_drv" ] && gpu_ver=$(modinfo -F version "$gpu_drv" 2>/dev/null || echo N/A)
fi
unset -f mesa_ver

# --- Motherboard & storage ---
mb_vendor=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null | xargs || true)
mb_name=$(cat /sys/class/dmi/id/board_name 2>/dev/null | xargs || true)
mb_ver=$(cat /sys/class/dmi/id/board_version 2>/dev/null | xargs || true)
mainboard="${mb_vendor:-unknown} ${mb_name:-unknown}${mb_ver:+ (${mb_ver})}"

storage=$(/usr/bin/lsblk -d -o NAME,SIZE,MODEL,TRAN --noheadings 2>/dev/null \
    | grep -vE '^(loop|zram)' | awk '{printf "  - /dev/%-10s %7s  %-30s [%s]\n", $1, $2, $3, $4}' || true)
storage="${storage:-  (no block devices detected)}"

# Full identify+health in one call (-a). USB bridges often misreport type -> retry
# with "-d sat". Serial is masked (last 4 chars) for forum-safe sharing.
smart=""
if command -v smartctl >/dev/null 2>&1; then
    get() { grep -iE "^$1:" <<< "$raw" | head -1 | sed -E 's/^[^:]+:[[:space:]]*//'; }
    while IFS= read -r line; do
        dev=$(awk '{print $1}' <<< "$line")
        tran=$(awk '{print $2}' <<< "$line")
        [ -b "/dev/$dev" ] || continue

        raw=$(smartctl -a "/dev/$dev" 2>/dev/null || true)
        if grep -qi 'Unable to detect device type\|Unknown USB bridge' <<< "$raw"; then
            raw=$(smartctl -a -d sat "/dev/$dev" 2>/dev/null || true)
        fi

        if [ -z "$raw" ]; then
            smart="${smart}  ------------------------------------------------------------\n  /dev/${dev} (${tran:-?}): no SMART data (unsupported device or no SMART capability)\n"
            continue
        fi

        serial=$(get "Serial Number")
        masked="n/a"
        [ -n "$serial" ] && masked="****${serial: -4}"
        health=$(grep -iE 'SMART overall-health|SMART Health Status' <<< "$raw" | head -1 | sed -E 's/^[^:]+:[[:space:]]*//')
        health="${health:-n/a}"

        if [[ "$dev" == nvme* ]]; then
            model=$(get "Model Number"); firmware=$(get "Firmware Version")
            capacity=$(get "Total NVM Capacity"); nvme_ver=$(get "NVMe Version")
            temp=$(get "Temperature"); used=$(get "Percentage Used")
            spare=$(get "Available Spare"); errs=$(get "Media and Data Integrity Errors")
            hours=$(get "Power On Hours")

            smart="${smart}  ------------------------------------------------------------\n"
            smart="${smart}  /dev/${dev} (${tran:-nvme})  ${model:-unknown}\n"
            smart="${smart}    Serial:          ${masked}\n"
            smart="${smart}    Firmware:        ${firmware:-n/a}\n"
            smart="${smart}    Capacity:        ${capacity:-n/a}\n"
            smart="${smart}    NVMe Version:    ${nvme_ver:-n/a}\n"
            smart="${smart}    Health:          ${health}\n"
            smart="${smart}    Percentage Used: ${used:-n/a}\n"
            smart="${smart}    Available Spare: ${spare:-n/a}\n"
            smart="${smart}    Media Errors:    ${errs:-n/a}\n"
            smart="${smart}    Power-On Hours:  ${hours:-n/a}\n"
            smart="${smart}    Temperature:     ${temp:-n/a}\n"
        else
            model_family=$(get "Model Family"); model=$(get "Device Model")
            firmware=$(get "Firmware Version"); capacity=$(get "User Capacity")
            rotation=$(get "Rotation Rate"); formfactor=$(get "Form Factor")
            sata_ver=$(get "SATA Version is")
            temp=$(awk '/Temperature_Celsius|Airflow_Temperature_Cel/{print $10; exit}' <<< "$raw")
            realloc=$(awk '/Reallocated_Sector_Ct/{print $10; exit}' <<< "$raw")
            pending=$(awk '/Current_Pending_Sector/{print $10; exit}' <<< "$raw")
            hours=$(awk '/Power_On_Hours/{print $10; exit}' <<< "$raw")
            wear=$(awk '/Wear_Leveling_Count|Media_Wearout_Indicator|SSD_Life_Left/{print $10; exit}' <<< "$raw")

            smart="${smart}  ------------------------------------------------------------\n"
            smart="${smart}  /dev/${dev} (${tran:-?})  ${model_family:+${model_family} }${model:-unknown}\n"
            smart="${smart}    Serial:          ${masked}\n"
            smart="${smart}    Firmware:        ${firmware:-n/a}\n"
            smart="${smart}    Capacity:        ${capacity:-n/a}\n"
            smart="${smart}    Type:            ${rotation:-n/a}${formfactor:+, ${formfactor}}\n"
            smart="${smart}    SATA:            ${sata_ver:-n/a}\n"
            smart="${smart}    Health:          ${health}\n"
            smart="${smart}    Power-On Hours:  ${hours:-n/a}\n"
            smart="${smart}    Realloc Sectors: ${realloc:-n/a}\n"
            smart="${smart}    Pending Sectors: ${pending:-n/a}\n"
            smart="${smart}    Wear Level:      ${wear:-n/a}\n"
            smart="${smart}    Temperature:     ${temp:-n/a}\n"
        fi
    done < <(/usr/bin/lsblk -d -o NAME,TRAN --noheadings 2>/dev/null | grep -vE '^(loop|zram)')
    smart="${smart:-  (no devices checked)}"
else
    smart="  N/A (smartctl / smartmontools not installed)"
fi

# --- Monitors (Plasma 6 kscreen-doctor) ---
monitors=""
if [ -n "$tmp_mon" ] && [ -s "$tmp_mon" ]; then
    monitors=$(awk '
    /^Output:/ {
        if (connector != "") printf "  Output: %-6s  %-12s @ %-10s  HDR: %-10s  VRR: %s\n", connector, geometry, refresh, hdr, vrr
        connector = $3; geometry = ""; refresh = ""; hdr = "N/A"; vrr = "N/A"
        next
    }
    /^\tGeometry:/ { n = split($0, a, " "); geometry = a[n]; next }
    /^\tModes:/ {
        if (match($0, /[0-9]+x[0-9]+@([0-9.]+)\*/, m)) {
            split(m[0], b, "@"); refresh = b[2]; gsub(/[*!]/, "", refresh); refresh = refresh " Hz"
        }
        next
    }
    /^\tHDR:/ { hdr = $2; next }
    /^\tVrr:/ { vrr = $2; next }
    END { if (connector != "") printf "  Output: %-6s  %-12s @ %-10s  HDR: %-10s  VRR: %s\n", connector, geometry, refresh, hdr, vrr }
    ' "$tmp_mon" || true)
fi

if [ -z "$monitors" ] && [ -n "$tmp_xrandr" ] && [ -s "$tmp_xrandr" ]; then
    monitors=$(awk '
        /^[A-Za-z0-9-]+ connected/ {
            if (conn != "") printf "  Output: %-8s  %-14s @ %s\n", conn, geom, refresh
            conn = $1; geom = "unknown"; refresh = "unknown"
            match($0, /[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/)
            if (RSTART > 0) geom = substr($0, RSTART, RLENGTH)
            next
        }
        /\*/ { for (i=1; i<=NF; i++) if ($i ~ /\*/) { refresh = $i; gsub(/\*|\+/, "", refresh); refresh = refresh " Hz" } }
        END { if (conn != "") printf "  Output: %-8s  %-14s @ %s\n", conn, geom, refresh }
    ' "$tmp_xrandr" || true)
    [ -n "$monitors" ] && monitors="  (via xrandr fallback - kscreen-doctor unavailable)"$'\n'"$monitors"
fi

if [ -z "$monitors" ]; then
    monitors="  (Monitor info from kscreen-doctor/xrandr unavailable)"
    shopt -s nullglob
    for conn_path in /sys/class/drm/card*-*/; do
        [ -f "${conn_path}status" ] || continue
        [ "$(cat "${conn_path}status" 2>/dev/null)" = "connected" ] || continue
        conn=$(basename "$conn_path")
        monitors="${monitors}"$'\n'"  - ${conn}: (DRM fallback; run kscreen-doctor/xrandr from user session)"
    done
    shopt -u nullglob
fi
monitors="${monitors:-  (no connected monitors detected)}"

# --- Displays via EDID (captured pre-relaunch: logind's uaccess ACL on the
# edid sysfs attribute belongs to the session, not generally to root) ---
edid_info=""
if [ -n "$tmp_edid" ] && [ -s "$tmp_edid" ]; then
    getf() { grep -m1 -iE "$1" <<< "$edid_raw" | sed -E 's/^[^:]+:[[:space:]]*//'; }
    while IFS= read -r conn; do
        edid_raw=$(awk -v c="$conn" '
            $0 == "===CONN:" c "===" { found=1; next }
            /^===CONN:/ { found=0 }
            found { print }
        ' "$tmp_edid")
        [ -z "$edid_raw" ] && continue

        manuf=$(getf "Manufacturer:")
        model=$(getf "^[[:space:]]*Model:")
        serial=$(getf "Serial Number:")
        masked="n/a"
        [ -n "$serial" ] && masked="****${serial: -4}"
        made=$(getf "Made in:")
        imgsize=$(getf "Maximum image size:")
        prodname=$(grep -m1 -iE 'Display Product Name:' <<< "$edid_raw" | sed -E "s/^[^:]+:[[:space:]]*//; s/^'//; s/'\$//")

        # Some panels set the CTA "native format" flag to a fallback (e.g. 1080p60)
        # instead of the real native res - take the largest resolution seen anywhere
        # in the EDID text (Established/Standard Timings, DTDs, CTA VICs) instead.
        maxres=$(grep -oE '[0-9]{3,5}x[0-9]{3,5}' <<< "$edid_raw" \
            | awk -Fx '{p=$1*$2; if(p>max){max=p; best=$0}} END{print best}')
        maxres_hz=""
        if [ -n "$maxres" ]; then
            maxres_hz=$(grep -F "$maxres" <<< "$edid_raw" \
                | grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]*Hz' | grep -oE '[0-9]+(\.[0-9]+)?' \
                | sort -n | tail -1)
            [ -n "$maxres_hz" ] && maxres_hz="${maxres_hz} Hz"
        fi

        edid_info="${edid_info}  ------------------------------------------------------------\n"
        edid_info="${edid_info}  ${conn}${prodname:+  (${prodname})}\n"
        edid_info="${edid_info}    Manufacturer:    ${manuf:-n/a}   Model: ${model:-n/a}\n"
        edid_info="${edid_info}    Serial:          ${masked}\n"
        edid_info="${edid_info}    Manufactured:    ${made:-n/a}\n"
        edid_info="${edid_info}    Panel size:      ${imgsize:-n/a}\n"
        edid_info="${edid_info}    Max resolution:  ${maxres:-n/a}${maxres_hz:+ @ ${maxres_hz}} (EDID)\n"
    done < <(grep -oE '^===CONN:.*===$' "$tmp_edid" | sed -E 's/^===CONN:(.*)===$/\1/')
    edid_info="${edid_info:-  (no connected displays with readable EDID found)}"
elif ! command -v edid-decode >/dev/null 2>&1; then
    edid_info="  N/A (edid-decode not installed)"
else
    edid_info="  (no EDID data captured in user session - is a display connected via DRM?)"
fi

# --- Network ---
nics=$(/usr/bin/lspci -mm 2>/dev/null | grep -iE '"(Ethernet|Network|Wireless|Wi-Fi|WLAN|InfiniBand)' \
    | awk -F'"' '{print "  - " $4 ": " $6}' || true)
nics="${nics:-  (none detected via lspci)}"

# ZeroTier interface names derive from the network ID and are treated as sensitive.
net_ifaces=$(ip -o link show 2>/dev/null | grep -v '^[0-9]*: lo:' | awk '{
    iface = $2; gsub(/:/, "", iface)
    state = ($0 ~ /state UP/) ? "UP" : "DOWN"
    type = "ethernet"
    if (iface ~ /^wl/)          type = "wifi"
    if (iface ~ /^zt/)        { type = "zerotier"; iface = "[redacted]" }
    if (iface ~ /^tun|^wg/)     type = "vpn"
    if (iface ~ /^br-|^virbr/){ type = "bridge";   iface = "[redacted]" }
    if (iface ~ /^br$/)         type = "bridge"
    if (iface ~ /^docker|^veth/) type = "container"
    printf "  - %-18s [%s]  state: %s\n", iface, type, state
}' || true)
net_ifaces="${net_ifaces:-  (none detected)}"

# resolvectl reports actual upstream DNS; /etc/resolv.conf under systemd-resolved
# is just the 127.0.0.53 stub and not useful here.
dns=""
if [ "$init_sys" = "systemd" ] && command -v resolvectl >/dev/null 2>&1; then
    dns=$(resolvectl status 2>/dev/null | awk '
        /^Link [0-9]+ \(/ { iface = $0; gsub(/.*\(|\).*/, "", iface) }
        /Current DNS Server:|DNS Servers:/ {
            for (i=NF; i>=1; i--)
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-fA-F:]+:[0-9a-fA-F:]+$/)
                    printf "  - %-10s %s\n", iface ":", $i
        }
    ' | sort -u || true)
fi
if [ -z "$dns" ]; then
    dns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep -v 127.0.0.53 | awk '{print "  - " $2}' || true)
fi
dns="${dns:-  (none configured or systemd-resolved stub only)}"

sound=$(/usr/bin/lspci 2>/dev/null | grep -iE 'Audio device' | sed 's/^/  [PCI] /' || true)
sound="${sound:-  (none detected)}"

# Filter out non-keyboard input nodes (power button, video bus, etc.) that the
# kernel also tags with a kbd event handler.
kbds=$(awk 'BEGIN{RS=""; FS="\n"}
    /Handlers=[^\n]*kbd/ {
        for (i=1;i<=NF;i++) if ($i ~ /^N:/) {
            name=$i; gsub(/N: Name=|"/,"",name)
            if (name !~ /[Pp]ower [Bb]utton|[Vv]ideo [Bb]us|[Pp][Cc] [Ss]peaker|[Ww][Mm][Ii]|[Cc]onsumer [Cc]ontrol|[Ss]ystem [Cc]ontrol/)
                print "  - " name
        }
    }' /proc/bus/input/devices 2>/dev/null | sort -u || true)
kbds="${kbds:-  (none detected)}"

mice=$(awk 'BEGIN{RS=""; FS="\n"}
    /Handlers=[^\n]*mouse/ {
        for (i=1;i<=NF;i++) if ($i ~ /^N:/) { gsub(/N: Name=|"/,"",$i); print "  - " $i }
    }' /proc/bus/input/devices 2>/dev/null | sort -u || true)
mice="${mice:-  (none detected)}"

swap_info=$(swapon --show=NAME,TYPE,SIZE,USED --noheadings 2>/dev/null \
    | awk '{printf "  - %-20s type: %-10s size: %-8s used: %s\n", $1, $2, $3, $4}' || true)
# zram-generator swap may not show up in swapon on first boot yet.
swap_info="${swap_info:-  (no active swap)}"
swap_total=$(awk '/^SwapTotal:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
swap_free=$(awk '/^SwapFree:/  {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)

# --- Repositories & glibc origin ---
opt_status="N/A (no pacman-based repo optimization concept on ${pkg_family})"
case "$pkg_family" in
    arch)
        repos=$(pacman-conf --repo-list 2>/dev/null | xargs || true)
        repos="${repos:-unknown}"
        first_repo=$(awk '{print $1}' <<< "$repos")
        glibc_ver=$(pacman -Q glibc 2>/dev/null | awk '{print $2}')
        glibc_ver="${glibc_ver:-unknown}"
        glibc_repo="unknown"
        for repo in $repos; do
            if pacman -Sl "$repo" 2>/dev/null | awk '{print $2}' | grep -qx glibc; then
                glibc_repo="$repo"
                break
            fi
        done
        # CachyOS ships CPU-tuned repos; glibc sourced from cachyos-znver4 confirms
        # the v4-optimized baseline is actually in effect, not just the repo being enabled.
        if [[ "$first_repo" == *cachyos-znver4* ]]; then
            if [[ "$glibc_repo" == *cachyos-znver4* ]]; then
                opt_status="VERIFIED (CachyOS znver4 baseline active)"
            else
                opt_status="PARTIAL (cachyos-znver4 repo active, glibc sourced from: ${glibc_repo})"
            fi
        elif [[ "$first_repo" == *cachyos* ]]; then
            opt_status="CachyOS (x86-64-v3 or generic)"
        else
            opt_status="Standard Arch Linux (no CPU-specific optimizations)"
        fi
        ;;
    debian)
        repos=$(find /etc/apt/sources.list.d -maxdepth 1 -name '*.list' -o -name '*.sources' 2>/dev/null \
            | xargs -n1 basename 2>/dev/null | tr '\n' ' ' || true)
        [ -f /etc/apt/sources.list ] && repos="sources.list ${repos}"
        repos="${repos:-unknown}"
        first_repo="(Debian/apt: no priority order like pacman - first file is not meaningful)"
        glibc_ver=$(dpkg-query -W -f='${Version}' libc6 2>/dev/null)
        glibc_ver="${glibc_ver:-unknown}"
        glibc_repo="N/A (apt has no per-package repo tagging like pacman -Sl)"
        ;;
    fedora)
        repos=$(dnf repolist --enabled -q 2>/dev/null | awk 'NR>1{print $1}' | xargs || true)
        repos="${repos:-unknown}"
        first_repo="(Fedora/dnf: no priority order like pacman)"
        glibc_ver=$(rpm -q --qf '%{VERSION}-%{RELEASE}' glibc 2>/dev/null)
        glibc_ver="${glibc_ver:-unknown}"
        glibc_repo=$(rpm -q --qf '%{VENDOR}' glibc 2>/dev/null)
        glibc_repo="${glibc_repo:-unknown}"
        ;;
    suse_rpm)
        repos=""
        command -v zypper >/dev/null 2>&1 && repos=$(zypper lr -s 2>/dev/null \
            | awk -F'|' 'NR>4{gsub(/^ +| +$/,"",$3); print $3}' | xargs || true)
        repos="${repos:-unknown}"
        first_repo="(RPM-based: no priority order like pacman)"
        glibc_ver=$(rpm -q --qf '%{VERSION}-%{RELEASE}' glibc 2>/dev/null)
        glibc_ver="${glibc_ver:-unknown}"
        glibc_repo=$(rpm -q --qf '%{VENDOR}' glibc 2>/dev/null)
        glibc_repo="${glibc_repo:-unknown}"
        ;;
    *)
        repos="N/A (no known package manager found)"
        first_repo="N/A" glibc_ver="N/A" glibc_repo="N/A"
        ;;
esac

# --- Kernel & microcode ---
kernel_run=$(uname -r)
kernel_params=$(cat /proc/cmdline 2>/dev/null || echo '(unavailable)')

case "$pkg_family" in
    arch)
        kernel_inst=$(pacman -Q 2>/dev/null | grep -E '^linux(-[a-z0-9]+([-][a-z0-9]+)*)? ' \
            | grep -v -- '-headers' | grep -v -- '-firmware' | awk '{print $1 " v" $2}' || true)
        ucode=$(pacman -Qq 2>/dev/null | grep -E '^(amd|intel)-ucode$' || true)
        ucode="${ucode:-NOT INSTALLED}"
        ;;
    debian)
        kernel_inst=$(dpkg-query -W -f='${Package} v${Version}\n' 'linux-image-*' 2>/dev/null | grep -v -- '-dbg' || true)
        if dpkg-query -W -f='${Status}\n' amd64-microcode 2>/dev/null | grep -q 'install ok'; then
            ucode="amd64-microcode installed"
        elif dpkg-query -W -f='${Status}\n' intel-microcode 2>/dev/null | grep -q 'install ok'; then
            ucode="intel-microcode installed"
        else
            ucode="NOT INSTALLED"
        fi
        ;;
    fedora)
        kernel_inst=$(rpm -qa --qf 'kernel v%{VERSION}-%{RELEASE}\n' 'kernel*' 2>/dev/null | grep -v -- '-devel\|-headers' || true)
        # Intel ships via microcode_ctl; AMD via the amd-ucode-firmware sub-package of linux-firmware.
        if rpm -q microcode_ctl >/dev/null 2>&1; then
            ucode="microcode_ctl installed (Intel)"
        elif rpm -q amd-ucode-firmware >/dev/null 2>&1; then
            ucode="amd-ucode-firmware installed (AMD)"
        else
            ucode="NOT INSTALLED"
        fi
        ;;
    suse_rpm)
        kernel_inst=$(rpm -qa --qf 'kernel v%{VERSION}-%{RELEASE}\n' 'kernel*' 2>/dev/null | grep -v -- '-devel\|-headers' || true)
        if rpm -q ucode-intel >/dev/null 2>&1; then
            ucode="ucode-intel installed"
        elif rpm -q ucode-amd >/dev/null 2>&1; then
            ucode="ucode-amd installed"
        else
            ucode="NOT INSTALLED"
        fi
        ;;
    *)
        kernel_inst="" ucode="N/A (unknown package manager)"
        ;;
esac

# --- Disk usage ---
disk_usage=$(df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null \
    | grep -vE '^(tmpfs|devtmpfs|efivarfs|Filesystem|overlay|udev)' \
    | awk '{printf "  %-30s %-8s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,$6,$7}' || true)
disk_usage="${disk_usage:-  (df failed)}"

crit=$(df -h 2>/dev/null | awk 'NR>1 && int($5) >= 90 {print "  ! WARNING: " $6 " is " $5 " full !"}' || true)
crit="${crit:-  No critical fill levels (>=90%).}"

if [ "$inc_svc" -eq 1 ]; then
    if [ "$init_sys" = "systemd" ]; then
        failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print "  ! " $1 " (" $2 ")"}' || true)
        failed_units="${failed_units:-  No failed units.}"
    else
        failed_units="  N/A (init system is ${init_sys}, not systemd)"
    fi

    if [ "$init_sys" = "systemd" ]; then
        svc_list=$(systemctl list-units --type=service --all --no-legend --plain 2>/dev/null | awk '
            {unit=$1; load=$2; active=$3; substate=$4; $1=$2=$3=$4=""; sub(/^ +/,"")
             printf "  - %-45s %-8s %-10s %-10s %s\n", unit, load, active, substate, $0}' || true)
        svc_list="${svc_list:-  (no service units found)}"
        svc_count=$(systemctl list-units --type=service --all --no-legend --plain 2>/dev/null | wc -l)

        # list-units only shows units systemd has loaded at least once; list-unit-files
        # additionally catches service units that exist but were never started.
        svc_files=$(systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null \
            | awk '{printf "  - %-45s %s\n", $1, $2}' || true)
        svc_files="${svc_files:-  (no service unit files found)}"
        svc_files_count=$(systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null | wc -l)
    elif command -v rc-status >/dev/null 2>&1; then
        svc_list=$(rc-status --servicelist 2>/dev/null | awk '{printf "  - %-30s %s\n", $1, $2}' || true)
        svc_list="${svc_list:-  (no services found via rc-status)}"
        svc_count=$(grep -c '^  - ' <<< "$svc_list")
        svc_files="  N/A (OpenRC has no unit-file inventory equivalent)"
        svc_files_count="n/a"
    else
        svc_list="  N/A (init system is ${init_sys}, no known service-status command)"
        svc_count="n/a"
        svc_files="  N/A (init system is ${init_sys})"
        svc_files_count="n/a"
    fi

    journal_errs=""
    if [ "$init_sys" = "systemd" ] && command -v journalctl >/dev/null 2>&1; then
        # -n counts journal entries, not lines - a multi-line coredump stacktrace
        # is one entry and comes through whole instead of being cut mid-trace.
        raw=$(journalctl -p err -b -n 30 --no-pager 2>/dev/null || true)
        if [ -z "$raw" ]; then
            journal_errs="  No error-level journal entries in current boot."
        else
            lc=$(wc -l <<< "$raw")
            if [ "$lc" -gt 200 ]; then
                journal_errs=$(head -n 200 <<< "$raw" | sed 's/^/  /')
                journal_errs="${journal_errs}
  [... truncated: ${lc} lines across the last 30 entries, capped here at 200 lines. Full output via: journalctl -p err -b -n 30 ...]"
            else
                journal_errs=$(sed 's/^/  /' <<< "$raw")
            fi
        fi
    else
        journal_errs="  N/A (journalctl unavailable or init system is ${init_sys})"
    fi

    dmesg_errs=""
    if command -v dmesg >/dev/null 2>&1; then
        dmesg_errs=$(dmesg -T -l err,warn 2>/dev/null | tail -n 30 | sed 's/^/  /' || true)
        dmesg_errs="${dmesg_errs:-  No error/warning-level kernel messages.}"
    else
        dmesg_errs="  N/A (dmesg unavailable)"
    fi
fi

# --- Proton / Wine ---
proton=""
caller_home=$(getent passwd "$caller" 2>/dev/null | cut -d: -f6)

steam_root=""
for candidate in "${caller_home}/.local/share/Steam" "${caller_home}/.steam/steam"; do
    [ -d "$candidate/steamapps" ] && steam_root="$candidate" && break
done

if [ -n "$steam_root" ]; then
    # Only "Proton X.Y" (official Valve releases) - excludes BattlEye/Hotfix/Next dirs.
    while IFS= read -r -d '' pdir; do
        pname=$(basename "$pdir")
        [[ "$pname" =~ ^Proton\ [0-9] ]] || continue
        proton="${proton}  - [Steam] ${pname}\n"
    done < <(find "$steam_root/steamapps/common" -maxdepth 1 -type d -print0 2>/dev/null)

    compat_dir="$steam_root/compatibilitytools.d"
    if [ -d "$compat_dir" ]; then
        while IFS= read -r -d '' tdir; do
            proton="${proton}  - [compat] $(basename "$tdir")\n"
        done < <(find "$compat_dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
    fi
fi

case "$pkg_family" in
    arch)
        sys_proton=$(pacman -Q 2>/dev/null | grep -iE '^(proton-|wine-cachyos|wine-staging|wine-tkg)' \
            | grep -viE '^(protonplus|protonup|protontricks)' | awk '{print "  - [pacman] " $1 " " $2}' || true)
        ;;
    debian)
        sys_proton=$(dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | grep -iE '^(wine|proton-)' \
            | grep -viE '^(protonplus|protonup|protontricks)' | awk '{print "  - [dpkg] " $1 " " $2}' || true)
        ;;
    fedora|suse_rpm)
        sys_proton=$(rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null | grep -iE '^(wine|proton-)' \
            | grep -viE '^(protonplus|protonup|protontricks)' | awk '{print "  - [rpm] " $1 " " $2}' || true)
        ;;
    *)
        sys_proton=""
        ;;
esac
[ -n "$sys_proton" ] && proton="${proton}${sys_proton}\n"
proton="${proton:-  (none found)}"

if [ "$inc_pkg" -eq 1 ]; then
    aur_helper="none"
    aur_updates=""
    aur_foreign=""
    if [ -n "$tmp_aur" ] && [ -s "$tmp_aur" ]; then
        aur_helper=$(grep '^HELPER=' "$tmp_aur" | cut -d= -f2)
        if [ "$aur_helper" != "none" ]; then
            aur_updates=$(sed -n '/^UPDATES_START$/,/^UPDATES_END$/p' "$tmp_aur" | grep -v '^UPDATES_')
            aur_foreign=$(sed -n '/^FOREIGN_START$/,/^FOREIGN_END$/p' "$tmp_aur" | grep -v '^FOREIGN_')
        fi
    fi
fi

tmp_report=$(mktemp /tmp/sys_audit_report.XXXXXX)
{
    printf '######################################################\n'
    printf '             SYSTEM AUDIT (host-tag: %s)\n' "$host_tag"
    printf '             TIMESTAMP: %s\n' "$ts"
    printf '######################################################\n'

    printf '\n[SYSTEM ENVIRONMENT]\n------------------------------------------------------\n'
    printf '%-30s : %s\n' "Distribution"        "${distro_pretty} (id: ${distro_id})"
    printf '%-30s : %s\n' "Init system"         "$init_sys"
    printf '%-30s : %s\n' "Virtualization"      "$virt"
    printf '%-30s : %s\n' "Desktop environment" "${xdg_de} (session: ${xdg_sess_de})"
    printf '%-30s : %s\n' "Session type"        "$xdg_sess_kind"
    printf '%-30s : %s\n' "Default shell"       "$def_shell"

    printf '\n[HARDWARE & GRAPHICS]\n------------------------------------------------------\n'
    printf '%-30s : %s (%s cores / %s threads)\n' "CPU model" "$cpu_full" "$cpu_cores" "$cpu_threads"
    printf '%-30s : %s\n' "Instruction set level" "$arch_lvl"
    printf '%-30s : %s\n' "GPU model"     "$gpu_models"
    printf '%-30s : %s\n' "Active driver" "${gpu_drv:-NONE}"
    printf '%-30s : %s\n' "Driver type"   "$gpu_type"
    printf '%-30s : %s\n' "Driver version" "$gpu_ver"
    printf '%-30s : %s\n' "GPU VRAM"      "$gpu_vram"

    printf '\n[MEMORY]\n------------------------------------------------------\n'
    printf '%-30s : %s  (available: %s)\n' "RAM total" "$ram_total" "$ram_avail"
    printf '\nDIMM slots:\n%s\n' "$ram_dimms"
    printf '\n%s\n' "$ram_xmp"
    printf '\nSwap:\n  Total: %s  Free: %s\n%s\n' "$swap_total" "$swap_free" "$swap_info"

    printf '\n[HARDWARE DETAILS]\n------------------------------------------------------\n'
    printf '%-30s : %s\n' "Motherboard" "$mainboard"
    printf '\nStorage devices:\n%s\n' "$storage"
    printf '\nSMART diagnostics:\n'
    printf '%b' "$smart"
    printf '\nMonitors:\n%s\n' "$monitors"
    printf '\nDisplays (EDID, DE-independent):\n'
    printf '%b' "$edid_info"
    printf '\nNetwork cards (NICs):\n%s\n' "$nics"
    printf '\nActive interfaces (IPs/MACs/sensitive names redacted):\n%s\n' "$net_ifaces"
    printf '\nSound cards:\n%s\n' "$sound"
    printf '\nKeyboards:\n%s\n' "$kbds"
    printf '\nMice:\n%s\n' "$mice"

    printf '\n[REPOSITORIES & OPTIMIZATION]\n------------------------------------------------------\n'
    printf '%-30s : %s\n' "Optimization status" "$opt_status"
    printf '%-30s : %s\n' "Primary repository"  "$first_repo"
    printf '%-30s : %s\n' "glibc version"       "$glibc_ver"
    printf '%-30s : %s\n' "glibc repo"          "$glibc_repo"
    printf '\nActive repositories/sources (%s%s):\n' "$pkg_family" "$([ "$pkg_family" = arch ] && echo ', priority order')"
    tr ' ' '\n' <<< "$repos" | sed 's/^/  - /'

    printf '\n[KERNEL & MICROCODE]\n------------------------------------------------------\n'
    printf '%-30s : %s\n' "Running kernel"   "$kernel_run"
    printf '%-30s : %s\n' "Microcode status" "$ucode"
    printf '\nInstalled kernel images:\n'
    if [ -n "$kernel_inst" ]; then
        sed 's/^/  - /' <<< "$kernel_inst"
    else
        printf '  (no kernel packages found via %s)\n' "$pkg_family"
    fi
    printf '\nKernel parameters:\n  %s\n' "$kernel_params"

    printf '\n[STORAGE & FILESYSTEM]\n------------------------------------------------------\n'
    findmnt -n -o SOURCE,FSTYPE,OPTIONS / 2>/dev/null \
        | awk '{printf "%-30s : %s (%s)\n", "Root mount", $1, $2}' \
        || printf '%-30s : %s\n' "Root mount" "(unable to determine)"
    printf '\nDisk usage (all mounts):\n%s\n' "$disk_usage"
    printf '\nCritical partitions (>=90%%):\n%s\n' "$crit"

    if [ "$inc_svc" -eq 1 ]; then
        printf '\n[SYSTEMD]\n------------------------------------------------------\n'
        printf 'Failed units:\n%s\n' "$failed_units"
        printf '\nService units - all states (count: %s):\n' "$svc_count"
        printf '  %-45s %-8s %-10s %-10s %s\n' "UNIT" "LOAD" "ACTIVE" "SUB" "DESCRIPTION"
        printf '%s\n' "$svc_list"
        printf '\nComplete service unit-file inventory, incl. never-loaded units (count: %s):\n%s\n' "$svc_files_count" "$svc_files"

        printf '\n[RECENT ERRORS (journalctl: last 30 entries, capped at 200 lines / dmesg: last 30 lines)]\n------------------------------------------------------\n'
        printf 'journalctl (priority: err):\n%s\n' "$journal_errs"
        printf '\ndmesg (priority: err, warn):\n%s\n' "$dmesg_errs"
    fi

    printf '\n[NETWORK]\n------------------------------------------------------\n'
    printf 'Note: IPs and MAC addresses redacted for public log sharing.\n'
    printf '\nDNS servers (upstream, via resolvectl):\n%s\n' "$dns"

    printf '\n[PROTON & WINE]\n------------------------------------------------------\n'
    printf '%b' "$proton"

    if [ "$inc_pkg" -eq 1 ]; then
        printf '\n[PACKAGE MANAGEMENT & AUR]\n------------------------------------------------------\n'
        if [ "$aur_helper" != "none" ]; then
            if [ -z "$aur_updates" ]; then
                printf 'AUR status: consistent (up to date)\n'
            else
                printf 'Pending AUR updates:\n%s\n' "$aur_updates"
            fi
            printf '\nInstalled foreign packages (AUR):\n'
            if [ -n "$aur_foreign" ]; then
                sed 's/^/  - /' <<< "$aur_foreign"
            else
                printf '  (none)\n'
            fi
        else
            printf 'AUR helper: none installed (paru/yay not found)\n'
        fi

        printf '\nActive Flatpak runtimes:\n'
        if command -v flatpak >/dev/null 2>&1; then
            flatpak list --columns=name,version 2>/dev/null | sed 's/^/  - /' \
                || printf '  (Flatpak present but no packages or error)\n'
        else
            printf '  No Flatpaks registered.\n'
        fi

        printf '\n[FULL PACKAGE INVENTORY (%s)]\n------------------------------------------------------\n' "$pkg_family"
        case "$pkg_family" in
            arch)
                printf '%-25s %-40s %s\n' "REPO" "PACKAGE" "VERSION"
                printf '%-25s %-40s %s\n' "----" "-------" "-------"
                pkglist=$(LC_ALL=C pacman -Sl 2>/dev/null | grep '\[installed' || true)
                if [ -n "$pkglist" ]; then
                    awk '{printf "%-25s %-40s %s\n", $1, $2, $3}' <<< "$pkglist"
                    printf '\nPackages per repository:\n'
                    awk '{print $1}' <<< "$pkglist" | sort | uniq -c | sort -rn | awk '{printf "  %-6s %s\n", $1, $2}'
                else
                    printf '  (pacman not available or error)\n'
                fi
                ;;
            debian)
                printf '%-40s %s\n' "PACKAGE" "VERSION"
                printf '%-40s %s\n' "-------" "-------"
                LC_ALL=C dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null \
                    | awk '{printf "%-40s %s\n", $1, $2}' \
                    || printf '  (dpkg not available or error)\n'
                printf "\nNote: apt/dpkg has no per-package repo tagging like pacman -Sl - 'per repository' breakdown does not apply.\n"
                ;;
            fedora|suse_rpm)
                printf '%-40s %s\n' "PACKAGE" "VERSION"
                printf '%-40s %s\n' "-------" "-------"
                pkglist=$(LC_ALL=C rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null | sort || true)
                if [ -n "$pkglist" ]; then
                    awk '{printf "%-40s %s\n", $1, $2}' <<< "$pkglist"
                    printf '\nPackages per vendor:\n'
                    LC_ALL=C rpm -qa --qf '%{VENDOR}\n' 2>/dev/null | sort | uniq -c | sort -rn | awk '{printf "  %-6s %s\n", $1, $2}'
                else
                    printf '  (rpm not available or error)\n'
                fi
                ;;
            *)
                printf '  N/A (no known package manager - pacman/dpkg/dnf/zypper/rpm not found)\n'
                ;;
        esac
        printf '\nNote: AUR/foreign packages not listed here (not in sync-repo DB) — see [PACKAGE MANAGEMENT & AUR] section above.\n'
    fi
} > "$tmp_report"

# mv/rename replaces the destination dentry directly rather than following it -
# avoids writing through a pre-planted symlink at a predictable, guessable $out
# while running as root.
if ! mv -f "$tmp_report" "$out"; then
    echo "Error: failed to move report into place: $out" >&2
    rm -f "$tmp_report"
    exit 1
fi

if [ -n "$caller" ] && id "$caller" >/dev/null 2>&1; then
    chown "${caller}:${caller}" "$out" 2>/dev/null || true
fi

printf '\nAudit complete: %s\n' "$out"
