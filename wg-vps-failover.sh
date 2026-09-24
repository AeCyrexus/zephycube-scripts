#!/usr/bin/env bash
# =============================================================================
# wg-vps-failover.sh  v1.0   — runs on each VPS relay
# =============================================================================
# The companion to wg-smart-route.sh (which runs on the LXC). The LXC daemon
# controls the RETURN path; this controls the INBOUND path. Without it, when
# Globe goes down the LXC fails over to PLDT but the VPS keeps DNAT'ing players
# into the dead Globe tunnel — so inbound traffic dies and every flow shows
# 1-way in wg-monitor.
#
# It health-checks each tunnel (pings the LXC tunnel IP over each wg interface)
# and repoints the inbound game DNAT to whichever tunnel is live, using the same
# policy as the LXC (Globe primary, fall back to PLDT, auto-recover) so the two
# ends converge on the SAME tunnel — which they must, or the return path breaks.
#
# Auto-detects which PoP this VPS is (Manila = wg1/wg2, Singapore = wg3/wg4).
#
# Subcommands: (default) run as a daemon | status | once | version
#              apply <globe|pldt>   (manual override, applied immediately)
#
# Changelog:
#   v1.0 — Inbound DNAT failover mirroring wg-smart-route's Globe-primary policy;
#          conntrack flush on switch; optional Discord; auto PoP detection.
# =============================================================================

set -uo pipefail
VERSION="1.0"

# ── Detect which PoP this VPS serves ──────────────────────────────────────────
# Globe is the primary tunnel (higher wg number); PLDT is the fallback.
if   ip link show wg2 &>/dev/null; then
    POP="Manila";    GLOBE_IF="wg2"; GLOBE_LXC="10.200.2.2"; PLDT_IF="wg1"; PLDT_LXC="10.200.1.2"
elif ip link show wg4 &>/dev/null; then
    POP="Singapore"; GLOBE_IF="wg4"; GLOBE_LXC="10.200.4.2"; PLDT_IF="wg3"; PLDT_LXC="10.200.3.2"
else
    echo "Cannot determine PoP: neither wg2 nor wg4 is present on this host." >&2
    exit 1
fi

# ── Config ────────────────────────────────────────────────────────────────────
WAN_IF="eth0"
# Inbound game ports to relay (proto dport). Edit if your ports change.
PORTS=(
    "tcp 2402:2406"
    "udp 2402:2406"
    "tcp 20000:20100"
    "udp 20000:20100"
    "tcp 25565"
    "udp 19132"
    "udp 19150"
)
PING_COUNT=3
PING_TIMEOUT=2
CHECK_INTERVAL=3
FAIL_THRESHOLD=3          # consecutive checks before failover / recovery
STATE_DIR="/var/run/wg-vps-failover"
LOG_FILE="/var/log/wg-vps-failover.log"
MAX_LOG_LINES=5000

# Optional Discord webhook (same env file as the LXC daemon). Empty = disabled.
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_USERNAME="${DISCORD_USERNAME:-wg-vps-failover}"

STATE_FILE="${STATE_DIR}/active"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${ts} [${POP}] $*" | tee -a "${LOG_FILE}"
    local lines; lines=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
    (( lines > MAX_LOG_LINES )) && { tail -n $((MAX_LOG_LINES/2)) "${LOG_FILE}" > "${LOG_FILE}.tmp"; mv "${LOG_FILE}.tmp" "${LOG_FILE}"; }
}

discord_notify() {
    [[ -z "${DISCORD_WEBHOOK_URL}" ]] && return 0
    local msg="$1" host; host=$(hostname 2>/dev/null || echo VPS)
    local payload; payload=$(printf '{"username":"%s","content":"**%s** — %s"}' "${DISCORD_USERNAME}" "${host}" "${msg}")
    curl -fsS -m 8 -H "Content-Type: application/json" -d "${payload}" "${DISCORD_WEBHOOK_URL}" >/dev/null 2>&1 &
}

get_state() { cat "${STATE_FILE}" 2>/dev/null || echo ""; }
set_state() { mkdir -p "${STATE_DIR}"; echo "$1" > "${STATE_FILE}"; }

# Ping the LXC tunnel IP over a specific tunnel interface.
reachable() { ping -I "$1" -c "${PING_COUNT}" -W "${PING_TIMEOUT}" -q "$2" &>/dev/null; }

# Remove every relay DNAT (to either LXC tunnel IP), then add the full port set
# pointing at the chosen target. Idempotent; also dedupes any duplicate rules.
set_dnat() {
    local target="$1" gesc pesc spec proto dport
    gesc="${GLOBE_LXC//./\\.}"; pesc="${PLDT_LXC//./\\.}"
    iptables -t nat -S PREROUTING 2>/dev/null \
        | grep -E -- "--to-destination (${gesc}|${pesc})(\b|$)" \
        | sed 's/^-A/-D/' \
        | while read -r rule; do
              # shellcheck disable=SC2086
              iptables -t nat ${rule} 2>/dev/null || true
          done
    for spec in "${PORTS[@]}"; do
        proto=${spec%% *}; dport=${spec##* }
        iptables -t nat -A PREROUTING -i "${WAN_IF}" -p "${proto}" --dport "${dport}" \
            -j DNAT --to-destination "${target}"
    done
    # Ensure MASQUERADE exists once for each tunnel (relay works on either).
    local ifc
    for ifc in "${GLOBE_IF}" "${PLDT_IF}"; do
        iptables -t nat -C POSTROUTING -o "${ifc}" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -o "${ifc}" -j MASQUERADE
    done
    # Clamp TCP MSS to the tunnel path MTU (1350) so large segments don't
    # black-hole through the tunnel. UDP unaffected.
    iptables -t mangle -C FORWARD -o wg+ -p tcp --syn -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -o wg+ -p tcp --syn -j TCPMSS --clamp-mss-to-pmtu
    # Drop stale conntrack so in-flight (1-way) flows re-DNAT to the live tunnel
    # now, instead of waiting out the UDP timeout.
    command -v conntrack &>/dev/null && conntrack -F &>/dev/null || true
}

# activate <globe|pldt> [reason]
activate() {
    local sel="$1" reason="${2:-switch}" target ifc cur
    cur=$(get_state)
    if [[ "${sel}" == "globe" ]]; then target="${GLOBE_LXC}"; ifc="${GLOBE_IF}"; else target="${PLDT_LXC}"; ifc="${PLDT_IF}"; fi
    if [[ "${sel}" == "${cur}" && "${reason}" != "initial" ]]; then return; fi

    set_dnat "${target}"
    set_state "${sel}"
    local label; [[ "${sel}" == "globe" ]] && label="Globe (${ifc})" || label="PLDT (${ifc})"
    log "inbound DNAT -> ${label} [${target}] (${reason})"
    case "${reason}" in
        failover) discord_notify "⚠️ ${POP}: inbound failover to ${label} — Globe tunnel down" ;;
        recovery) discord_notify "✅ ${POP}: inbound recovered to ${label}" ;;
        initial)  : ;;
        *)        discord_notify "🔁 ${POP}: inbound now via ${label}" ;;
    esac
}

current_dnat_target() {
    iptables -t nat -S PREROUTING 2>/dev/null | grep -m1 -oE -- '--to-destination [0-9.]+' | awk '{print $2}'
}

print_status() {
    local g="DOWN" p="DOWN"
    reachable "${GLOBE_IF}" "${GLOBE_LXC}" && g="up"
    reachable "${PLDT_IF}"  "${PLDT_LXC}"  && p="up"
    echo "wg-vps-failover v${VERSION}  —  ${POP}"
    echo "  active (state): $(get_state 2>/dev/null || echo unknown)"
    echo "  inbound DNAT -> $(current_dnat_target 2>/dev/null || echo none)"
    printf "  Globe %-5s %-14s %s\n" "(${GLOBE_IF})" "-> ${GLOBE_LXC}" "${g}"
    printf "  PLDT  %-5s %-14s %s\n" "(${PLDT_IF})"  "-> ${PLDT_LXC}"  "${p}"
}

# ── Subcommands ───────────────────────────────────────────────────────────────
case "${1:-run}" in
    version) echo "wg-vps-failover v${VERSION}"; exit 0 ;;
    status)  print_status; exit 0 ;;
esac

[[ "${EUID}" -ne 0 ]] && { echo "Must run as root."; exit 1; }
mkdir -p "${STATE_DIR}"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

case "${1:-run}" in
    apply)
        case "${2:-}" in
            globe) activate globe initial ;;
            pldt)  activate pldt  initial ;;
            *) echo "usage: $0 apply <globe|pldt>"; exit 1 ;;
        esac
        exit 0 ;;
    once|run) : ;;
    *) echo "usage: $0 [run|once|status|version|apply <globe|pldt>]"; exit 1 ;;
esac

# Decide the best tunnel right now (Globe preferred), apply immediately.
decide_and_apply() {
    if reachable "${GLOBE_IF}" "${GLOBE_LXC}"; then echo globe
    elif reachable "${PLDT_IF}" "${PLDT_LXC}"; then echo pldt
    else echo ""; fi
}

initial=$(decide_and_apply)
if [[ -n "${initial}" ]]; then activate "${initial}" initial
else log "WARNING: neither tunnel reachable at startup — leaving DNAT as-is"; fi

[[ "${1:-run}" == "once" ]] && exit 0

log "wg-vps-failover v${VERSION} monitoring ${POP} (Globe primary, PLDT fallback)"
fail_count=0; recover_count=0
while true; do
    cur=$(get_state)
    globe_ok=0; pldt_ok=0
    reachable "${GLOBE_IF}" "${GLOBE_LXC}" && globe_ok=1
    reachable "${PLDT_IF}"  "${PLDT_LXC}"  && pldt_ok=1

    if [[ "${cur}" == "globe" ]]; then
        if (( globe_ok )); then
            fail_count=0
        else
            (( fail_count++ )) || true
            log "Globe check failed (${fail_count}/${FAIL_THRESHOLD})"
            if (( fail_count >= FAIL_THRESHOLD )); then
                if (( pldt_ok )); then activate pldt failover
                else log "Globe down but PLDT also unreachable — holding"; fi
                fail_count=0
            fi
        fi
    else   # currently on PLDT (or unset)
        if (( globe_ok )); then
            (( recover_count++ )) || true
            log "Globe recovery check (${recover_count}/${FAIL_THRESHOLD})"
            if (( recover_count >= FAIL_THRESHOLD )); then activate globe recovery; recover_count=0; fi
        else
            recover_count=0
            # If we somehow have no active tunnel and PLDT is up, take it.
            [[ -z "${cur}" ]] && (( pldt_ok )) && activate pldt failover
        fi
    fi
    sleep "${CHECK_INTERVAL}"
done
