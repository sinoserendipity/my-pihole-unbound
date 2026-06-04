# syntax=docker/dockerfile:1

ARG PIHOLE_VERSION=2026.05.0
FROM pihole/pihole:${PIHOLE_VERSION}

ARG PIHOLE_VERSION
LABEL org.opencontainers.image.title="Pi-hole Unbound Sentinel"
LABEL org.opencontainers.image.description="Pi-hole v6 with Unbound recursive DNS and a lightweight sentinel monitor"
LABEL org.opencontainers.image.source="https://github.com/username/my-pihole-unbound"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.base.name="pihole/pihole:${PIHOLE_VERSION}"

RUN apk add --no-cache \
      ca-certificates \
      unbound \
    && install -d -m 0755 /etc/unbound/unbound.conf.d /var/lib/unbound /var/log/unbound \
    && chown -R unbound:unbound /var/lib/unbound /var/log/unbound

COPY docker/unbound/unbound.conf /etc/unbound/unbound.conf
COPY docker/dnsmasq.d/99-edns.conf /etc/dnsmasq.d/99-edns.conf
COPY docker/entrypoint.sh /usr/local/bin/pihole-unbound-entrypoint.sh

RUN chmod 0755 /usr/local/bin/pihole-unbound-entrypoint.sh

EXPOSE 53/tcp 53/udp 80/tcp 443/tcp

ENTRYPOINT ["/usr/local/bin/pihole-unbound-entrypoint.sh"]
