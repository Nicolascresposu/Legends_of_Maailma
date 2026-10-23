# syntax=docker/dockerfile:1
#
# The Maailma server, in three targets:
#
#   build    — full install and compile; also what `migrate` runs from.
#   migrate  — applies pending Prisma migrations, then exits.
#   runtime  — the server alone, with production dependencies only.
#
# See docs/deployment.md for how deploy/docker-compose.yml wires them together.

FROM node:22-bookworm-slim AS base
# Prisma's engines link against OpenSSL, which the slim image leaves out.
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app

FROM base AS build
# Manifests first, so a source edit does not re-run the install.
COPY package.json package-lock.json ./
COPY apps/server/package.json apps/server/
COPY packages/card-definitions/package.json packages/card-definitions/
COPY packages/game-engine/package.json packages/game-engine/
COPY packages/game-model/package.json packages/game-model/
COPY packages/protocol/package.json packages/protocol/
COPY packages/rng/package.json packages/rng/
COPY prisma/schema.prisma prisma/
RUN npm ci
COPY tsconfig.base.json tsconfig.json ./
COPY prisma prisma
COPY packages packages
COPY scripts scripts
COPY apps/server apps/server
RUN npx prisma generate && npm run build

FROM build AS migrate
CMD ["npx", "prisma", "migrate", "deploy"]

FROM base AS runtime
ENV NODE_ENV=production
COPY package.json package-lock.json ./
COPY apps/server/package.json apps/server/
COPY packages/card-definitions/package.json packages/card-definitions/
COPY packages/game-engine/package.json packages/game-engine/
COPY packages/game-model/package.json packages/game-model/
COPY packages/protocol/package.json packages/protocol/
COPY packages/rng/package.json packages/rng/
# The Prisma CLI is a dev dependency, so the client generated here would be a
# stub: drop it and take the real one from the build stage.
RUN npm ci --omit=dev && rm -rf node_modules/.prisma && npm cache clean --force
COPY --from=build /app/node_modules/.prisma node_modules/.prisma
COPY --from=build /app/packages/card-definitions/dist packages/card-definitions/dist
COPY --from=build /app/packages/card-definitions/content packages/card-definitions/content
COPY --from=build /app/packages/card-definitions/content.schema.json packages/card-definitions/content.schema.json
COPY --from=build /app/packages/game-engine/dist packages/game-engine/dist
COPY --from=build /app/packages/game-model/dist packages/game-model/dist
COPY --from=build /app/packages/protocol/dist packages/protocol/dist
COPY --from=build /app/packages/rng/dist packages/rng/dist
COPY --from=build /app/apps/server/dist apps/server/dist
RUN mkdir -p /var/lib/maailma/content && chown -R node:node /var/lib/maailma
USER node
ENV CONTENT_STORE_DIR=/var/lib/maailma/content
ENV PORT=3000
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
CMD ["node", "apps/server/dist/index.js"]
