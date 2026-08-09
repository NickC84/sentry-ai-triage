# Container image — the "already running containers / want it on a server"
# path. For a laptop, the release zip is simpler: it needs no mounts.
#
# Two things cannot be baked in and must be mounted at run time:
#   - your Claude credentials  (-v ~/.claude:/root/.claude)
#   - the app repo the AI reads for feature analysis and draft PRs
# See docker-compose.yml.

# ── 1 · web UI ────────────────────────────────────────────────────────
FROM ghcr.io/cirruslabs/flutter:3.24.0 AS ui
WORKDIR /src
COPY ui/pubspec.yaml ui/pubspec.lock ./ui/
RUN cd ui && flutter pub get
COPY ui ./ui
RUN cd ui && flutter build web --no-web-resources-cdn

# ── 2 · backend binaries ──────────────────────────────────────────────
FROM dart:3.5 AS backend
ARG APP_VERSION=dev
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart pub get --offline \
 && for entry in serve ingest analyze feature; do \
      out="/out/sentry-triage"; \
      [ "$entry" = "serve" ] || out="/out/sentry-triage-$entry"; \
      dart compile exe "bin/$entry.dart" -o "$out" -DAPP_VERSION="$APP_VERSION"; \
    done

# ── 3 · runtime ───────────────────────────────────────────────────────
FROM debian:bookworm-slim

# git + gh + the Claude CLI are the tool's hands: without them the container
# can analyze nothing and open nothing.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg git libsqlite3-0 \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs gh \
 && npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force \
 && apt-get purge -y --auto-remove gnupg \
 && rm -rf /var/lib/apt/lists/*

# A bind-mounted repo is owned by the host user, not by root — without this
# every git call in the draft-PR flow fails with "dubious ownership".
RUN git config --global --add safe.directory '*'

WORKDIR /app
COPY --from=backend /out/ /app/
COPY --from=ui /src/ui/build/web /app/web
COPY rules /app/rules

# Anchor data/config next to the mounted volume, and listen on all interfaces
# so the published port actually reaches the server.
ENV TRIAGE_HOME=/app \
    HOST=0.0.0.0 \
    PORT=8787 \
    NO_OPEN=1

VOLUME ["/app/data"]
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD curl -sf http://localhost:8787/api/health || exit 1

CMD ["/app/sentry-triage"]
