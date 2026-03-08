# ── Stage 1: Extensions setup ──────────────────────────────────
ARG OPENCLAW_EXTENSIONS=""
ARG OPENCLAW_VARIANT=default
ARG OPENCLAW_NODE_BOOKWORM_IMAGE="node:22-bookworm@sha256:b501c082306a4f528bc4038cbf2fbb58095d583d0419a259b2114b5ac53d12e9"
ARG OPENCLAW_NODE_BOOKWORM_DIGEST="sha256:b501c082306a4f528bc4038cbf2fbb58095d583d0419a259b2114b5ac53d12e9"
ARG OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE="node:22-bookworm-slim@sha256:9c2c405e3ff9b9afb2873232d24bb06367d649aa3e6259cbe314da59578e81e9"
ARG OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST="sha256:9c2c405e3ff9b9afb2873232d24bb06367d649aa3e6259cbe314da59578e81e9"

FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS ext-deps
ARG OPENCLAW_EXTENSIONS
COPY extensions /tmp/extensions
RUN mkdir -p /out && \
    for ext in $OPENCLAW_EXTENSIONS; do \
      if [ -f "/tmp/extensions/$ext/package.json" ]; then \
        mkdir -p "/out/$ext" && \
        cp "/tmp/extensions/$ext/package.json" "/out/$ext/package.json"; \
      fi; \
    done

# ── Stage 2: Build ──────────────────────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS build
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts
COPY --from=ext-deps /out/ ./extensions/
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile
COPY . .
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# ── Runtime base images ─────────────────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS base-default
ARG OPENCLAW_NODE_BOOKWORM_DIGEST
FROM ${OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE} AS base-slim
ARG OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST

# ── Stage 3: Runtime ────────────────────────────────────────────
FROM base-${OPENCLAW_VARIANT}
ARG OPENCLAW_VARIANT
WORKDIR /app

# Установка системных утилит + Gemini CLI
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      procps hostname curl git openssl ca-certificates && \
    npm install -g @google/gemini-cli && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Копируем файлы из билда (сохраняем структуру твоего файла)
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json .
COPY --from=build /app/openclaw.mjs .
COPY --from=build /app/extensions ./extensions
COPY --from=build /app/skills ./skills
COPY --from=build /app/docs ./docs

RUN corepack enable && \
    corepack prepare "$(node -p "require('./package.json').packageManager")" --activate

# Права доступа для Gemini CLI
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw && \
    chmod 755 /app/openclaw.mjs && \
    mkdir -p /root/.config/google-gemini-cli && \
    chmod -R 777 /root/.config

ENV NODE_ENV=production
# Принудительно заставляем бота слушать внешний порт Railway
ENV OPENCLAW_BIND=lan 

# Оставляем твой Healthcheck
HEALTHCHECK --interval=3m --timeout=10s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Модифицированная команда запуска: создаем конфиг из переменной и стартуем
USER root
CMD sh -c '\
  if [ -n "$GEMINI_CONFIG_JSON" ]; then \
    mkdir -p /root/.gemini && \
    echo "$GEMINI_CONFIG_JSON" > /root/.gemini/oauth_creds.json; \
  fi && \
  NODE_OPTIONS="--max-old-space-size=6144" node openclaw.mjs gateway --allow-unconfigured & \
  sleep 15 && \
  if [ -n "$MY_PAIRING_CODE" ]; then \
    echo "Approving Telegram pairing code: $MY_PAIRING_CODE" && \
    node openclaw.mjs pairing approve telegram "$MY_PAIRING_CODE" || true; \
  fi && \
  wait'
