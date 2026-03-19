FROM alpine:3.20
RUN apk add --no-cache docker-cli curl
COPY gluetun-qbt-watchdog.sh /gluetun-qbt-watchdog.sh
RUN chmod +x /gluetun-qbt-watchdog.sh
CMD ["/gluetun-qbt-watchdog.sh"]
