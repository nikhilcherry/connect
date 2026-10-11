# Starts the Connect backend (Supabase stack + edge functions) by driving the
# host's Docker, so a friend needs nothing installed but Docker.
FROM docker:27-cli AS dockercli

FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends bash curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g supabase@2.101.0 \
    && npm cache clean --force
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
