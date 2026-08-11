ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG OPENWRT_VERSION
ARG OPENCLASH_VERSION

LABEL org.opencontainers.image.title="OpenWrt with OpenClash"
LABEL org.openwrt.version="${OPENWRT_VERSION}"
LABEL org.openclash.version="${OPENCLASH_VERSION}"

COPY build/openclash.apk /tmp/openclash.apk

RUN set -eux; \
    apk update; \
    apk add \
        bash \
        dnsmasq-full \
        curl \
        ca-bundle \
        ip-full \
        ruby \
        ruby-yaml \
        kmod-tun \
        kmod-inet-diag \
        unzip \
        kmod-nft-tproxy \
        luci-compat \
        luci \
        luci-base; \
    apk add \
        -q \
        --force-overwrite \
        --clean-protected \
        --allow-untrusted \
        /tmp/openclash.apk; \
    apk info -e luci-app-openclash; \
    rm -f /tmp/openclash.apk; \
    /etc/init.d/uhttpd enable || true

CMD ["/sbin/init"]
