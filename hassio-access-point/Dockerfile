FROM ghcr.io/home-assistant/base:latest

LABEL \
  io.hass.type="app" \
  io.hass.name="Lifely Access Point" \
  io.hass.description="Create a WiFi access point to directly connect devices to Home Assistant" \
  io.hass.url="https://github.com/cr0ssn0tice/Hassio-Access-Point-priv"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV LANG=C.UTF-8

RUN apk update && \
    apk add --no-cache \
      bash \
      iw \
      hostapd \
      networkmanager \
      net-tools \
      sudo \
      dnsmasq \
      iptables && \
    rm -rf /var/cache/apk/*

COPY hostapd.conf /
COPY dnsmasq.conf /
COPY run.sh /

RUN chmod +x /run.sh

CMD ["/run.sh"]
