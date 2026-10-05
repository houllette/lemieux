FROM node:20-bookworm-slim AS base
ARG PNPM_VERSION=8.10.0
RUN corepack enable && corepack prepare "pnpm@${PNPM_VERSION}" --activate
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm build
CMD ["pnpm", "start"]
