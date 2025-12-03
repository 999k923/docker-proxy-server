FROM ubuntu:22.04

RUN apt update && apt install -y curl openssl uuid-runtime

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV SERVICE_TYPE=1  # 1: hy2, 2: tuic

EXPOSE 28888/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
