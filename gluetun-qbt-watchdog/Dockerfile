FROM alpine:3.20

LABEL org.opencontainers.image.source="https://github.com/brunoorsolon/gluetun-qbt-watchdog"
LABEL org.opencontainers.image.description="Keeps Gluetun forwarded ports synced with qBittorrent"
LABEL org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache docker-cli curl
COPY gluetun-qbt-watchdog.sh /gluetun-qbt-watchdog.sh
RUN chmod +x /gluetun-qbt-watchdog.sh
CMD ["/gluetun-qbt-watchdog.sh"]
