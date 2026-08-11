#!/bin/sh

set -eu

log() {
    echo "[OpenWrt Docker] $*"
}

ensure_config_file() {
    file="$1"
    mkdir -p /etc/config
    [ -f "/etc/config/${file}" ] || : > "/etc/config/${file}"
}

log "Container startup..."

# The official release rootfs can start without generated UCI files in a
# container. Make the packages we manage explicitly available before UCI use.
ensure_config_file network
ensure_config_file dhcp
ensure_config_file firewall

# ---------------------------------------------------------------------------
# Network: one-arm IPv4 side router
# ---------------------------------------------------------------------------

log "Applying LAN network settings..."

# We do not use separate WAN interfaces in this container topology.
uci -q delete network.wan || true
uci -q delete network.wan6 || true

# Keep a conventional loopback section even when the raw rootfs did not
# generate one before first boot.
uci set network.loopback='interface'
uci set network.loopback.device='lo'
uci set network.loopback.proto='static'
uci set network.loopback.ipaddr='127.0.0.1'
uci set network.loopback.netmask='255.0.0.0'

uci set network.lan='interface'
uci set network.lan.device='eth0'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="${OWRT_IP}"
uci set network.lan.netmask="${OWRT_NETMASK}"
uci set network.lan.gateway="${OWRT_GATEWAY}"

uci -q delete network.lan.dns || true
uci add_list network.lan.dns="${OWRT_DNS}"

uci commit network

# ---------------------------------------------------------------------------
# DHCP / IPv6 advertisement safety
# ---------------------------------------------------------------------------

log "Enforcing DHCP/RA disabled state..."

uci set dhcp.lan='dhcp'
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.ndp='disabled'
uci commit dhcp

# ---------------------------------------------------------------------------
# Firewall: same-interface forwarding + masquerade for one-arm routing
# ---------------------------------------------------------------------------

log "Applying LAN firewall/NAT settings..."

LAN_ZONE="$(
    uci show firewall 2>/dev/null \
        | sed -n "s/^\(firewall\.[^=]*\)\.name='lan'$/\1/p" \
        | head -n 1
)"

if [ -z "${LAN_ZONE}" ]; then
    LAN_ZONE='firewall.side_lan'
    uci set "${LAN_ZONE}=zone"
    uci set "${LAN_ZONE}.name=lan"
fi

uci -q delete "${LAN_ZONE}.network" || true
uci add_list "${LAN_ZONE}.network=lan"
uci set "${LAN_ZONE}.input=ACCEPT"
uci set "${LAN_ZONE}.output=ACCEPT"
uci set "${LAN_ZONE}.forward=ACCEPT"
uci set "${LAN_ZONE}.masq=1"
uci set "${LAN_ZONE}.mtu_fix=1"
uci commit firewall

# ---------------------------------------------------------------------------
# OpenClash runtime data
# ---------------------------------------------------------------------------

mkdir -p /etc/openclash/core

# Seed the persistent OpenClash volume only when it has no core yet.
# Future core updates performed by OpenClash are therefore preserved.
if [ ! -x /etc/openclash/core/clash_meta ]; then
    if [ -f /bootstrap/clash_meta ]; then
        log "Seeding Mihomo core from /bootstrap/clash_meta..."
        cp /bootstrap/clash_meta /etc/openclash/core/clash_meta
        chmod 0755 /etc/openclash/core/clash_meta
    else
        log "WARNING: Mihomo core is absent; install it from OpenClash before enabling the proxy."
    fi
fi

if [ -x /etc/openclash/core/clash_meta ]; then
    CORE_VERSION="$(/etc/openclash/core/clash_meta -v 2>/dev/null | head -n 1 || true)"
    [ -n "${CORE_VERSION}" ] && log "Mihomo core: ${CORE_VERSION}"
fi

log "IP       : ${OWRT_IP}"
log "Gateway  : ${OWRT_GATEWAY}"
log "DHCP     : disabled"
log "IPv6 RA  : disabled"
log "LAN NAT  : enabled"
log "Starting OpenWrt init..."

exec /sbin/init
