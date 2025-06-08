#!/bin/bash
set -euo pipefail

# === 設定 ===
IFACE="eth0"
PHY_ADDR=0
RETRY_MAX=3
SNR_THRESHOLD=40
TIMEOUT=20  # Increased for 3km
LOGFILE="/var/log/adin1100_init.log"
DRYRUN=0

# Note: Configure logrotate for $LOGFILE to prevent unbounded growth.
# Example /etc/logrotate.d/adin1100:
# /var/log/adin1100_init.log {
#     daily
#     rotate 7
#     compress
#     missingok
# }

# === 引数処理 ===
while [[ "${1:-}" != "" ]]; do
    case $1 in
        --dry-run ) DRYRUN=1 ;;
        -* ) echo "Unknown option: $1"; exit 2 ;;
        * )
            if [[ -z "${IFACE_SET:-}" ]]; then
                IFACE="$1"; IFACE_SET=1
            elif [[ -z "${PHY_ADDR_SET:-}" ]]; then
                PHY_ADDR="$1"; PHY_ADDR_SET=1
            elif [[ -z "${REPEATER_PHY_ADDR_SET:-}" ]]; then
                REPEATER_PHY_ADDR="$1"; REPEATER_PHY_ADDR_SET=1
            fi
            ;;
    esac
    shift
done

# === 依存ツール確認 ===
command -v mdio >/dev/null || {
    echo "[$(date '+%F %T')] ERROR: mdio command not found. Please install mdio-tools."
    exit 1
}
command -v ethtool >/dev/null || {
    echo "[$(date '+%F %T')] ERROR: ethtool not found. Please install ethtool."
    exit 1
}
command -v ip >/dev/null || {
    echo "[$(date '+%F %T')] ERROR: ip command not found. Please install iproute2."
    exit 1
}
command -v tput >/dev/null || {
    echo "[$(date '+%F %T')] WARNING: tput not found. Color output disabled."
}

# === 検証 ===
if ! ip link show "${IFACE}" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] ERROR: Interface ${IFACE} does not exist"
    exit 1
fi
if [ "${PHY_ADDR}" -lt 0 ] || [ "${PHY_ADDR}" -gt 31 ]; then
    echo "[$(date '+%F %T')] ERROR: Invalid PHY address (${PHY_ADDR}). Must be 0-31."
    exit 1
fi
if [ -n "${REPEATER_PHY_ADDR:-}" ] && { [ "${REPEATER_PHY_ADDR}" -lt 0 ] || [ "${REPEATER_PHY_ADDR}" -gt 31 ]; }; then
    echo "[$(date '+%F %T')] ERROR: Invalid repeater PHY address (${REPEATER_PHY_ADDR}). Must be 0-31."
    exit 1
fi

LOGDIR=$(dirname "${LOGFILE}")
if [ ! -d "${LOGDIR}" ]; then
    mkdir -p "${LOGDIR}" || {
        echo "[$(date '+%F %T')] ERROR: Cannot create log directory ${LOGDIR}"
        exit 1
    }
fi
if [ ! -w "${LOGDIR}" ]; then
    echo "[$(date '+%F %T')] ERROR: No write permission for ${LOGDIR}"
    exit 1
fi

# === ログ関数 ===
log() {
    local msg="$1"
    local color_reset=""
    local color=""
    if [ -t 1 ] && command -v tput >/dev/null; then  # Terminal with tput
        color_reset=$(tput sgr0)
        case "$msg" in
            *ERROR*|*⚠️*) color=$(tput setaf 1) ;;  # Red
            *✅*|*📶*OK*) color=$(tput setaf 2) ;;  # Green
            *⏳*) color=$(tput setaf 3) ;;  # Yellow
            *) color="" ;;
        esac
        echo "${color}[$(date '+%F %T')] ${msg}${color_reset}"
    else
        echo "[$(date '+%F %T')] ${msg}"
    fi
    echo "[$(date '+%F %T')] ${msg}" >> "${LOGFILE}"
}

mdio_write() {
    [ "${DRYRUN}" -eq 1 ] && { log "[DRYRUN] MDIO write: reg=$1, val=$2"; return 0; }
    mdio write "${IFACE}" "${PHY_ADDR}" "$1" "$2" 2>/dev/null || {
        log "ERROR: MDIO write failed (reg=$1, val=$2)"
        return 1
    }
    log "MDIO write: reg=$1, val=$2"
    return 0
}

mdio_read() {
    [ "${DRYRUN}" -eq 1 ] && {
        local val=$((RANDOM % 65536))
        log "[DRYRUN] MDIO read: reg=$1, val=0x$(printf '%04X' $val)"
        echo "$val"
        return 0
    }
    local val=$(mdio read "${IFACE}" "${PHY_ADDR}" "$1" 2>/dev/null)
    if [ -z "${val}" ]; then
        log "ERROR: MDIO read failed (reg=$1)"
        return 1
    fi
    val=$((0xFFFF & val))
    log "MDIO read: reg=$1, val=0x$(printf '%04X' $val)"
    echo "$val"
    return 0
}

configure_phy() {
    log "PHY long-reach configuration started..."
    mdio_write 0x1F 0x0002 || return 1
    mdio_write 0x1A 0x8001 || return 1

    start_time=$(date +%s)
    while true; do
        val=$(mdio_read 0x1A) || return 1
        [ $((val & 0x8000)) -eq 0 ] && break
        [ $(( $(date +%s) - start_time )) -gt "${TIMEOUT}" ] && {
            log "ERROR: Cable diagnostics timeout"
            return 1
        }
        sleep 0.5
    done
    cable_len=$((val & 0x0FFF))
    log "Cable diagnostics completed (length: ${cable_len} meters)"
    [ "${cable_len}" -gt 1700 ] && log "⚠️ Cable length (${cable_len} m) exceeds 1.7km. Repeater strongly recommended."
    [ "${cable_len}" -gt 1000 ] && [ "${cable_len}" -le 1700 ] && log "⚠️ Cable length (${cable_len} m) is near standard limit (1.7km). Ensure high-quality cable."

    mdio_write 0x1B 0x0001 || return 1
    start_time=$(date +%s)
    while true; do
        val=$(mdio_read 0x1B) || return 1
        [ $((val & 0x0001)) -eq 0 ] && break
        [ $(( $(date +%s) - start_time )) -gt "${TIMEOUT}" ] && {
            log "ERROR: Calibration timeout"
            return 1
        }
        sleep 0.5
    done
    log "Calibration completed"

    mdio_write 0x2D 0x00C0 || return 1  # 2.4Vpp
    mdio_write 0x2E 0x0100 || return 1  # Rx EQ
    log "PHY Tx/Rx long-reach settings applied"

    mdio_write 0x1F 0x0000 || return 1

    ethtool -s "${IFACE}" autoneg off speed 10 duplex full 2>/dev/null || {
        log "ERROR: ethtool configuration failed"
        return 1
    }
    log "ethtool configuration completed"
    return 0
}

check_link() {
    for i in $(seq 1 "${RETRY_MAX}"); do
        sleep 1
        link=$(ethtool "${IFACE}" | grep "Link detected" | awk '{print $3}')
        if [ "${link}" = "yes" ]; then
            log "✅ Link established successfully (ethtool)"
            return 0
        else
            mdio_write 0x1F 0x0000 || return 1
            val=$(mdio_read 0x0001) || return 1
            if [ $((val & 0x0004)) -ne 0 ]; then
                log "✅ Link established successfully (MDIO)"
                return 0
            fi
            log "⏳ Link not yet established (attempt $i/${RETRY_MAX})"
            [ "$i" -lt "${RETRY_MAX}" ] && {
                log "Resetting PHY for retry..."
                mdio_write 0x1F 0x0000 || return 1
                mdio_write 0x0000 0x8000 || return 1
                sleep 1
                configure_phy || return 1
            }
        fi
    done
    log "❌ Failed to establish link"
    return 1
}

check_snr() {
    local snr_attempts=2
    local attempt=1
    snr=0

    mdio_write 0x1F 0x0002 || return 1
    while [ "$attempt" -le "$snr_attempts" ]; do
        val=$(mdio_read 0x1C) || return 1
        snr=$((val & 0x00FF))
        if [ "$snr" -lt "${SNR_THRESHOLD}" ]; then
            log "⚠️ Low SNR detected ($snr < ${SNR_THRESHOLD}, attempt $attempt/$snr_attempts)"
            if [ "$attempt" -lt "$snr_attempts" ]; then
                log "Re-running calibration..."
                mdio_write 0x1B 0x0001 || return 1
                start_time=$(date +%s)
                while true; do
                    val=$(mdio_read 0x1B) || return 1
                    [ $((val & 0x0001)) -eq 0 ] && break
                    [ $(( $(date +%s) - start_time )) -gt "${TIMEOUT}" ] && {
                        log "ERROR: Re-calibration timeout"
                        return 1
                    }
                    sleep 0.5
                done
                log "Re-calibration completed"
                val=$(mdio_read 0x1C) || return 1
                snr=$((val & 0x00FF))
                log "📶 SNR after recalibration: $snr dB"
            else
                log "⚠️ SNR still low. Check cable or consider a repeater."
            fi
        else
            [ "$snr" -lt 50 ] && log "⚠️ Marginal SNR ($snr dB). Monitor link stability."
            [ "$snr" -ge 50 ] && log "📶 SNR OK ($snr dB)"
            break
        fi
        attempt=$((attempt + 1))
    done
    mdio_write 0x1F 0x0000 || return 1
    return 0
}

# === 既存リンク確認 ===
if [ "${DRYRUN}" -eq 0 ] && ethtool "${IFACE}" | grep -q "Link detected: yes"; then
    log "✅ Link already established on ${IFACE}. Skipping initialization."
    exit 0
fi

# === 環境情報 ===
log "System: $(uname -a)"
log "Interface Info: $(ip addr show "${IFACE}" | grep -A2 "${IFACE}")"

# === リピータ設定 ===
if [ -n "${REPEATER_PHY_ADDR:-}" ]; then
    log "Configuring repeater PHY at address ${REPEATER_PHY_ADDR}"
    TEMP_PHY_ADDR=${PHY_ADDR}
    PHY_ADDR=${REPEATER_PHY_ADDR}
    configure_phy || log "WARNING: Repeater configuration failed"
    PHY_ADDR=${TEMP_PHY_ADDR}
fi

# === メイン処理 ===
log "==== ADIN1100 initialization started (interface: ${IFACE}, PHY: ${PHY_ADDR}) ===="
configure_phy || { log "ERROR: PHY configuration failed"; exit 1; }
check_link || { log "ERROR: Link establishment failed"; exit 1; }
check_snr || { log "ERROR: SNR check failed"; exit 1; }

# === 完了ログ ===
log "==== Initialization completed successfully ===="
log "📏 Final cable length: ${cable_len} m"
log "📶 Final SNR: ${snr} dB"
exit 0
