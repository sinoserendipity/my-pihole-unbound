# syntax=docker/dockerfile:1

ARG PIHOLE_VERSION=2026.05.0
FROM pihole/pihole:${PIHOLE_VERSION}

ARG PIHOLE_VERSION
ARG TARGETARCH=amd64
ARG TARGETVARIANT=
ARG S6_OVERLAY_VERSION=3.2.3.0

LABEL org.opencontainers.image.title="Pi-hole Unbound s6"
LABEL org.opencontainers.image.description="Pi-hole v6 with Unbound recursive DNS supervised by s6-overlay"
LABEL org.opencontainers.image.source="https://github.com/username/my-pihole-unbound"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.base.name="pihole/pihole:${PIHOLE_VERSION}"

RUN apk add --no-cache \
      ca-certificates \
      dns-root-hints \
      dnssec-root \
      wget \
      xz \
      unbound \
    && install -d -m 0755 /etc/unbound/unbound.conf.d /var/lib/unbound /var/log/unbound \
    && chown -R unbound:unbound /var/lib/unbound /var/log/unbound

RUN set -eux; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
      amd64*) s6_arch="x86_64" ;; \
      arm64*) s6_arch="aarch64" ;; \
      armv7) s6_arch="armhf" ;; \
      armv6) s6_arch="arm" ;; \
      *) echo "Unsupported architecture: TARGETARCH=${TARGETARCH} TARGETVARIANT=${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    base_url="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    wget -O /tmp/s6-overlay-noarch.tar.xz "${base_url}/s6-overlay-noarch.tar.xz"; \
    wget -O /tmp/s6-overlay-noarch.tar.xz.sha256 "${base_url}/s6-overlay-noarch.tar.xz.sha256"; \
    wget -O "/tmp/s6-overlay-${s6_arch}.tar.xz" "${base_url}/s6-overlay-${s6_arch}.tar.xz"; \
    wget -O "/tmp/s6-overlay-${s6_arch}.tar.xz.sha256" "${base_url}/s6-overlay-${s6_arch}.tar.xz.sha256"; \
    cd /tmp; \
    sha256sum -c s6-overlay-noarch.tar.xz.sha256; \
    sha256sum -c "s6-overlay-${s6_arch}.tar.xz.sha256"; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf "/tmp/s6-overlay-${s6_arch}.tar.xz"; \
    rm -f /tmp/s6-overlay-*.tar.xz /tmp/s6-overlay-*.tar.xz.sha256

COPY docker/unbound/unbound.conf /etc/unbound/unbound.conf
COPY docker/dnsmasq.d/99-edns.conf /etc/dnsmasq.d/99-edns.conf
COPY docker/root/ /

RUN chmod 0755 \
      /etc/cont-init.d/10-unbound-anchor \
      /etc/services.d/unbound/run \
      /etc/services.d/pihole/run

EXPOSE 53/tcp 53/udp 80/tcp 443/tcp

ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2
ENTRYPOINT ["/init"]
