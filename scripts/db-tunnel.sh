#!/usr/bin/env bash
#
# Open an SSM port-forwarding tunnel from your laptop to a private VPC
# resource (RDS Postgres or ElastiCache Redis) through the bastion.
# Leave this terminal running while you connect locally.
#
# Usage:
#   scripts/db-tunnel.sh [env] [target] [local-port]
#
#   env         staging (default) — bastion is staging-only
#   target      postgres (default) | redis
#   local-port  auto: 5432 for postgres, 6379 for redis
#
# Examples:
#   scripts/db-tunnel.sh                          # postgres on :5432
#   scripts/db-tunnel.sh staging redis            # redis on :6379
#   scripts/db-tunnel.sh staging postgres 15432   # postgres on :15432
#
# Prereqs:
#   - AWS CLI v2 with credentials configured for the ap-south-1 account
#   - SSM Session Manager plugin (`brew install --cask session-manager-plugin`)
#   - The bastion module has been applied

set -euo pipefail

ENV="${1:-staging}"
TARGET="${2:-postgres}"
LOCAL_PORT="${3:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${REPO_ROOT}/infra/terraform/envs/${ENV}"

if [[ ! -d "${ENV_DIR}" ]]; then
  echo "Error: env directory not found: ${ENV_DIR}" >&2
  echo "Valid envs: staging" >&2
  exit 1
fi

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  echo "Error: session-manager-plugin not installed." >&2
  echo "Install: brew install --cask session-manager-plugin" >&2
  exit 1
fi

pushd "${ENV_DIR}" >/dev/null

INSTANCE_ID="$(terraform output -raw bastion_instance_id)"

case "${TARGET}" in
  postgres|pg|rds)
    REMOTE_HOST="$(terraform output -raw db_address)"
    REMOTE_PORT="$(terraform output -raw db_port)"
    LOCAL_PORT="${LOCAL_PORT:-5432}"
    LABEL="Postgres"
    ;;
  redis|cache|elasticache)
    REMOTE_HOST="$(terraform output -raw redis_primary_endpoint)"
    REMOTE_PORT="$(terraform output -raw redis_port)"
    LOCAL_PORT="${LOCAL_PORT:-6379}"
    LABEL="Redis"
    ;;
  *)
    echo "Error: unknown target '${TARGET}'. Use postgres or redis." >&2
    exit 1
    ;;
esac

popd >/dev/null

echo "→ ${LABEL} tunnel: localhost:${LOCAL_PORT} → ${REMOTE_HOST}:${REMOTE_PORT}"
echo "  bastion: ${INSTANCE_ID}"
echo "  (Ctrl+C to close)"
echo

exec aws ssm start-session \
  --target "${INSTANCE_ID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=[\"${REMOTE_HOST}\"],portNumber=[\"${REMOTE_PORT}\"],localPortNumber=[\"${LOCAL_PORT}\"]"
