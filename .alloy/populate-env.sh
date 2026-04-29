#!/usr/bin/env bash
# Populate apps/web/.env for the Dub Alloy dev stack.
#
# - Idempotent: safe to run more than once.
# - Reads existing values from apps/web/.env first; only fills blanks or
#   documented placeholders.
# - Pulls real secrets from the current process environment when present,
#   otherwise generates local-dev-safe defaults.
# - Never overwrites a non-blank user-provided value.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/apps/web/.env"

mkdir -p "$(dirname "${ENV_FILE}")"
touch "${ENV_FILE}"

# Read an existing env value; treat blanks and "xx" placeholders as missing.
get_existing() {
  local key="$1"
  local val
  val="$(awk -F= -v k="${key}" '
    BEGIN { found="" }
    $0 ~ "^"k"=" {
      sub("^"k"=", "")
      gsub(/^"|"$/, "")
      found=$0
    }
    END { print found }
  ' "${ENV_FILE}")"
  printf '%s' "${val}"
}

# Set a key in the env file:
#   set_env KEY VALUE [overwrite-empty-only]
# If the env file already has KEY set to a non-blank, non-"xx" value, leave it
# alone. Otherwise write VALUE.
set_env() {
  local key="$1"
  local value="$2"
  local existing
  existing="$(get_existing "${key}")"
  if [[ -n "${existing}" && "${existing}" != "xx" && "${existing}" != "PLACEHOLDER" ]]; then
    return 0
  fi

  # Build the line we want.
  local line
  line="${key}=${value}"

  # If the key exists (even if blank/placeholder), replace its line in place;
  # otherwise append.
  if grep -q "^${key}=" "${ENV_FILE}"; then
    # Use a temp file to avoid sed delimiter pitfalls with values containing /.
    local tmp
    tmp="$(mktemp)"
    awk -v k="${key}" -v v="${line}" '
      BEGIN { replaced=0 }
      {
        if ($0 ~ "^"k"=") { print v; replaced=1 }
        else { print $0 }
      }
      END {
        if (!replaced) { print v }
      }
    ' "${ENV_FILE}" > "${tmp}"
    mv "${tmp}" "${ENV_FILE}"
  else
    printf '%s\n' "${line}" >> "${ENV_FILE}"
  fi
}

# Take the value from the current process environment if it is set and
# non-empty; otherwise use the provided default.
from_env_or() {
  local var_name="$1"
  local default_value="$2"
  local current="${!var_name-}"
  if [[ -n "${current}" ]]; then
    printf '%s' "${current}"
  else
    printf '%s' "${default_value}"
  fi
}

# Generate a local-dev-safe NEXTAUTH secret if the user has not set one.
gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# ---------------------------------------------------------------------------
# Required: app identity
# ---------------------------------------------------------------------------
set_env "NEXT_PUBLIC_APP_NAME"         "$(from_env_or NEXT_PUBLIC_APP_NAME "Dub")"
set_env "NEXT_PUBLIC_APP_DOMAIN"       "$(from_env_or NEXT_PUBLIC_APP_DOMAIN "localhost:8888")"
set_env "NEXT_PUBLIC_APP_SHORT_DOMAIN" "$(from_env_or NEXT_PUBLIC_APP_SHORT_DOMAIN "dub.sh")"

# ---------------------------------------------------------------------------
# Required: NextAuth
# ---------------------------------------------------------------------------
existing_secret="$(get_existing NEXTAUTH_SECRET)"
if [[ -z "${existing_secret}" || "${existing_secret}" == "xx" ]]; then
  set_env "NEXTAUTH_SECRET" "$(from_env_or NEXTAUTH_SECRET "$(gen_secret)")"
fi
set_env "NEXTAUTH_URL"     "$(from_env_or NEXTAUTH_URL "http://localhost:8888")"

# ---------------------------------------------------------------------------
# Required: database (host-network MySQL + PlanetScale HTTP simulator)
# ---------------------------------------------------------------------------
set_env "DATABASE_URL"             "$(from_env_or DATABASE_URL "mysql://root:@localhost:3306/planetscale")"
set_env "PLANETSCALE_DATABASE_URL" "$(from_env_or PLANETSCALE_DATABASE_URL "http://root:unused@localhost:3900/planetscale")"

# ---------------------------------------------------------------------------
# Required: Upstash Redis – served by serverless-redis-http on host:80
# (the hiett/serverless-redis-http image binds port 80; nothing else in this
# stack listens there).
# ---------------------------------------------------------------------------
set_env "UPSTASH_REDIS_REST_URL"   "$(from_env_or UPSTASH_REDIS_REST_URL "http://localhost:80")"
set_env "UPSTASH_REDIS_REST_TOKEN" "$(from_env_or UPSTASH_REDIS_REST_TOKEN "alloy_local_dev_token")"

# ---------------------------------------------------------------------------
# Stubs for third-party services we don't run locally.
# These are accepted as placeholders by the app so it can boot. They are not
# valid credentials and will not authenticate against any real provider.
# ---------------------------------------------------------------------------
set_env "TINYBIRD_API_KEY" "$(from_env_or TINYBIRD_API_KEY "xx")"
set_env "TINYBIRD_API_URL" "$(from_env_or TINYBIRD_API_URL "https://api.tinybird.co")"

set_env "QSTASH_TOKEN"               "$(from_env_or QSTASH_TOKEN "xx")"
set_env "QSTASH_CURRENT_SIGNING_KEY" "$(from_env_or QSTASH_CURRENT_SIGNING_KEY "xx")"
set_env "QSTASH_NEXT_SIGNING_KEY"    "$(from_env_or QSTASH_NEXT_SIGNING_KEY "xx")"

set_env "UPSTASH_VECTOR_REST_URL"   "$(from_env_or UPSTASH_VECTOR_REST_URL "https://example-vector.upstash.io")"
set_env "UPSTASH_VECTOR_REST_TOKEN" "$(from_env_or UPSTASH_VECTOR_REST_TOKEN "xx")"

# SMTP – mailhog is not in the minimal stack, but populating these prevents
# the Resend client from throwing during boot.
set_env "SMTP_HOST"     "$(from_env_or SMTP_HOST "localhost")"
set_env "SMTP_PORT"     "$(from_env_or SMTP_PORT "1025")"
set_env "SMTP_USER"     "$(from_env_or SMTP_USER "smtpUser")"
set_env "SMTP_PASSWORD" "$(from_env_or SMTP_PASSWORD "smtpPassword")"

set_env "EMBEDDING_SYNC_SECRET" "$(from_env_or EMBEDDING_SYNC_SECRET "xx")"

# ---------------------------------------------------------------------------
# Alloy runtime hint
# ---------------------------------------------------------------------------
set_env "IS_ALLOY" "$(from_env_or IS_ALLOY "true")"

echo "Wrote ${ENV_FILE}"
