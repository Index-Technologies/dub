#!/usr/bin/env bash
# Bootstrap and run the Dub Next.js dev server inside the Alloy compose `web`
# service.
#
# Steps:
#   1. enable corepack + pnpm at the repo's pinned version
#   2. install workspace deps (idempotent; subsequent runs are fast)
#   3. generate the Prisma client from the schema
#   4. wait for MySQL to accept TCP connections
#   5. push the Prisma schema into the local MySQL (idempotent)
#   6. exec `next dev` on port 8888

set -euo pipefail

cd /workspace

# Pin pnpm to the version declared in package.json's packageManager field.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
corepack enable
corepack prepare pnpm@9.15.9 --activate

# Avoid build-script prompts when running unattended.
export CI=true
export PNPM_DEDICATED_LOCKFILE=true
export NEXT_TELEMETRY_DISABLED=1

# Use a workspace-local pnpm store so it survives between container restarts.
export PNPM_STORE_DIR=/workspace/.pnpm-store

echo "[alloy] installing workspace dependencies"
pnpm install --prefer-offline --config.confirmModulesPurge=false

echo "[alloy] generating prisma client"
pnpm --filter @dub/prisma generate

# `@dub/utils`, `@dub/ui`, etc. are workspace packages whose package.json points
# at `./dist/index.mjs`. They are NOT in next.config.js's `transpilePackages`
# list, so the Next dev server can't resolve them until they've been built at
# least once. `pnpm build:packages` is idempotent and fast on rebuilds.
if [[ ! -d packages/utils/dist || ! -d packages/ui/dist ]]; then
  echo "[alloy] building workspace packages (one-time)"
  pnpm build:packages
fi

echo "[alloy] waiting for MySQL on 127.0.0.1:3306"
for i in $(seq 1 120); do
  if (echo > /dev/tcp/127.0.0.1/3306) >/dev/null 2>&1; then
    echo "[alloy] MySQL is up"
    break
  fi
  sleep 2
done

echo "[alloy] pushing prisma schema (idempotent)"
# `db push` is safe to re-run; it syncs the schema without migrations.
pnpm --filter @dub/prisma push --accept-data-loss --skip-generate || {
  echo "[alloy] prisma push failed; retrying once after a short wait"
  sleep 5
  pnpm --filter @dub/prisma push --accept-data-loss --skip-generate
}

echo "[alloy] starting next dev on :8888"
cd apps/web
exec pnpm exec next dev --turbopack --port 8888 --hostname 0.0.0.0
