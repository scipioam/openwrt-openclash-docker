#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
SERVICE_NAME="openwrt-host-shim.service"
HELPER_PATH="/usr/local/sbin/openwrt-host-shim"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

[ -f "${ENV_FILE}" ] || { echo "Missing ${ENV_FILE}" >&2; exit 1; }

get_env_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "${ENV_FILE}" | tail -n 1
}

OPENWRT_IP="$(get_env_value OPENWRT_IP)"
HOST_SHIM_IP="$(get_env_value OPENWRT_HOST_SHIM_IP)"
PARENT_IF="enp1s0"
SHIM_IF="openwrt-host"

[[ "${OPENWRT_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Invalid OPENWRT_IP: ${OPENWRT_IP}" >&2
    exit 1
}

[[ "${HOST_SHIM_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Invalid OPENWRT_HOST_SHIM_IP: ${HOST_SHIM_IP}" >&2
    exit 1
}

sudo tee "${HELPER_PATH}" >/dev/null <<EOF_HELPER
#!/usr/bin/env bash
set -e

case "\${1:-}" in
    up)
        ip link delete ${SHIM_IF} 2>/dev/null || true
        ip link add ${SHIM_IF} link ${PARENT_IF} type macvlan mode bridge
        ip addr add ${HOST_SHIM_IP}/32 dev ${SHIM_IF}
        ip link set ${SHIM_IF} up
        ip route replace ${OPENWRT_IP}/32 dev ${SHIM_IF} src ${HOST_SHIM_IP}
        ;;
    down)
        ip route del ${OPENWRT_IP}/32 dev ${SHIM_IF} 2>/dev/null || true
        ip link delete ${SHIM_IF} 2>/dev/null || true
        ;;
    *)
        echo "Usage: \$0 {up|down}" >&2
        exit 2
        ;;
esac
EOF_HELPER

sudo chmod 0755 "${HELPER_PATH}"

sudo tee "${SERVICE_PATH}" >/dev/null <<EOF_SERVICE
[Unit]
Description=Host macvlan shim for Docker OpenWrt
After=network-online.target docker.service
Wants=network-online.target
Before=cloudflared.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HELPER_PATH} up
ExecStop=${HELPER_PATH} down

[Install]
WantedBy=multi-user.target
EOF_SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

systemctl --no-pager --full status "${SERVICE_NAME}" || true
ip route get "${OPENWRT_IP}"
