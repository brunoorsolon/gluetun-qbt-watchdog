FROM alpine:3.20

LABEL org.opencontainers.image.source="https://github.com/brunoorsolon/gluetun-qbt-watchdog"
LABEL org.opencontainers.image.description="Keeps Gluetun forwarded ports synced with qBittorrent"
LABEL org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache docker-cli curl python3 tini
COPY gluetun-qbt-watchdog.sh recovery.sh health-server.py /
RUN chmod +x /gluetun-qbt-watchdog.sh && mkdir /state
EXPOSE 8081
ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD ["/gluetun-qbt-watchdog.sh"]
