#!/usr/bin/env bash
# =============================================================================
# wg-vps-bootstrap.sh — fast (re)deploy of a PoP VPS
# =============================================================================
# A fresh OS has no WireGuard keys — a reformat DESTROYS the old ones. This
# generates new keypairs on this box and wires them to pop-control's EXISTING
# public keys (pop-control's own keys don't change — only this VPS's do). At
# the end it prints this VPS's NEW public keys: paste them into pop-control's
# wgX.conf [Peer] PublicKey fields, or the tunnel will never handshake.
#
# Usage:
#   sudo ./wg-vps-bootstrap.sh <mnl|sgp> <lxc_pldt_pubkey> <lxc_globe_pubkey>
#
# Get those two values FIRST, on pop-control (pick the pair for the PoP you're
# deploying — wg1/wg2 for mnl, wg3/wg4 for sgp):
#   wg show wg1 public-key   /   wg show wg3 public-key   (PLDT)
#   wg show wg2 public-key   /   wg show wg4 public-key   (Globe)
# =============================================================================

set -euo pipefail

[[ "${EUID}" -ne 0 ]] && { echo "Run as root."; exit 1; }
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <mnl|sgp> <lxc_pldt_pubkey> <lxc_globe_pubkey>"
    exit 1
fi
POP_ARG="$1"
LXC_PLDT_PUBKEY="$2"
LXC_GLOBE_PUBKEY="$3"

case "${POP_ARG}" in
    mnl) PLDT_IF=wg1; GLOBE_IF=wg2; PLDT_PORT=51821; GLOBE_PORT=51822; PLDT_ADDR=10.200.1.1; GLOBE_ADDR=10.200.2.1 ;;
    sgp) PLDT_IF=wg3; GLOBE_IF=wg4; PLDT_PORT=51823; GLOBE_PORT=51824; PLDT_ADDR=10.200.3.1; GLOBE_ADDR=10.200.4.1 ;;
    *) echo "First argument must be 'mnl' or 'sgp', got '${POP_ARG}'"; exit 1 ;;
esac

log() { echo "[vps-bootstrap:${POP_ARG}] $*"; }

# ── 1. Packages ────────────────────────────────────────────────────────────
log "Installing packages"
apt-get update -qq
apt-get install -y -qq wireguard iptables conntrack curl >/dev/null

# ── 2. Forwarding (persisted) ────────────────────────────────────────────────
log "Enabling IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-wg-vps.conf << 'EOF'
net.ipv4.ip_forward = 1
EOF

# ── 3. Keys + configs (idempotent — won't clobber an existing deploy) ────────
mkdir -p /etc/wireguard
umask 077

for pair in "${PLDT_IF} ${PLDT_PORT} ${PLDT_ADDR} ${LXC_PLDT_PUBKEY}" "${GLOBE_IF} ${GLOBE_PORT} ${GLOBE_ADDR} ${LXC_GLOBE_PUBKEY}"; do
    read -r ifc port addr peer <<< "${pair}"
    conf="/etc/wireguard/${ifc}.conf"
    if [[ -f "${conf}" ]]; then
        log "${conf} already exists — leaving it as-is (delete it first to regenerate)"
        continue
    fi
    log "Generating keypair for ${ifc}"
    priv=$(wg genkey)
    pub=$(echo "${priv}" | wg pubkey)
    cat > "${conf}" << EOF
[Interface]
Address    = ${addr}/30
ListenPort = ${port}
PrivateKey = ${priv}

[Peer]
PublicKey  = ${peer}
# No Endpoint here — pop-control has no stable public IP; WireGuard learns
# its endpoint from incoming packets (its own PersistentKeepalive keeps it
# fresh). AllowedIPs 0.0.0.0/0 is load-bearing, matches the LXC side — do
# not tighten it.
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "${conf}"
    echo "${ifc} new public key: ${pub}" >> /root/wg-vps-bootstrap-newkeys.txt
done

# ── 4. Bring tunnels up + enable at boot ─────────────────────────────────────
for ifc in "${PLDT_IF}" "${GLOBE_IF}"; do
    log "Bringing up ${ifc}"
    wg-quick up "${ifc}" 2>/dev/null || log "  (already up)"
    systemctl enable "wg-quick@${ifc}" >/dev/null 2>&1
done

# ── 5. wg-vps-failover ────────────────────────────────────────────────────
# Prefer a sibling file (e.g. a full git clone); if this script was fetched
# standalone (a lone `wget` of just this file), pull the other two from the
# same repo instead of failing.
REPO_RAW="https://raw.githubusercontent.com/AeCyrexus/zephycube-scripts/refs/heads/main"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILOVER_SH="${SRC_DIR}/wg-vps-failover.sh"
FAILOVER_SVC="${SRC_DIR}/wg-vps-failover.service"

if [[ ! -f "${FAILOVER_SH}" || ! -f "${FAILOVER_SVC}" ]]; then
    log "wg-vps-failover.sh/.service not found locally — fetching from the repo"
    TMP_FETCH="$(mktemp -d)"
    if curl -fsSL "${REPO_RAW}/wg-vps-failover.sh" -o "${TMP_FETCH}/wg-vps-failover.sh" \
       && curl -fsSL "${REPO_RAW}/wg-vps-failover.service" -o "${TMP_FETCH}/wg-vps-failover.service"; then
        FAILOVER_SH="${TMP_FETCH}/wg-vps-failover.sh"
        FAILOVER_SVC="${TMP_FETCH}/wg-vps-failover.service"
    else
        log "WARNING: fetch failed — install wg-vps-failover.sh/.service manually"
        FAILOVER_SH=""; FAILOVER_SVC=""
    fi
fi

if [[ -n "${FAILOVER_SH}" && -f "${FAILOVER_SH}" ]]; then
    log "Installing wg-vps-failover"
    install -m 0755 "${FAILOVER_SH}" /usr/local/sbin/wg-vps-failover.sh
    install -m 0644 "${FAILOVER_SVC}" /etc/systemd/system/wg-vps-failover.service
    systemctl daemon-reload
    systemctl enable --now wg-vps-failover
fi

log "Done."
echo
echo "=================================================================="
echo " NEW PUBLIC KEYS — paste these into pop-control's configs NOW:"
echo "=================================================================="
cat /root/wg-vps-bootstrap-newkeys.txt 2>/dev/null || echo "  (no new keys generated — configs already existed)"
echo
echo " On pop-control:"
echo "   edit /etc/wireguard/${PLDT_IF}.conf [Peer] PublicKey -> ${PLDT_IF}'s new key above"
echo "   edit /etc/wireguard/${GLOBE_IF}.conf [Peer] PublicKey -> ${GLOBE_IF}'s new key above"
echo "   wg-quick down ${PLDT_IF} && wg-quick up ${PLDT_IF}"
echo "   wg-quick down ${GLOBE_IF} && wg-quick up ${GLOBE_IF}"
echo "   sudo wg-diagnostic.sh          # expect both tunnels green"
echo "=================================================================="
