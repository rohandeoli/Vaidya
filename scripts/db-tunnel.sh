#!/usr/bin/env bash
#
# Open an SSM port-forwarding tunnel from your laptop to the RDS instance
# through the bastion. Leave this terminal running while you connect with
# DBeaver / psql to localhost:<local-port>.
#
# Usage:
#   scripts/db-tunnel.sh [env] [local-port]
#
#   env         staging (default) — bastion is staging-only
#   local-port  5432 (default)
#
# Prereqs:
#   - AWS CLI v2 with credentials configured for the ap-south-1 account
#   - SSM Session Manager plugin (`brew install --cask session-manager-plugin`)
#   - The bastion module has been applied (outputs `bastion_instance_id`)

set -euo pipefail

ENV="${1:-staging}"
LOCAL_PORT="${2:-5432}"

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
DB_HOST="$(terraform output -raw db_address)"
DB_PORT="$(terraform output -raw db_port)"

popd >/dev/null

echo "→ Tunneling localhost:${LOCAL_PORT} → ${DB_HOST}:${DB_PORT}"
echo "  bastion: ${INSTANCE_ID}"
echo "  (Ctrl+C to close)"
echo

exec aws ssm start-session \
  --target "${INSTANCE_ID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=[\"${DB_HOST}\"],portNumber=[\"${DB_PORT}\"],localPortNumber=[\"${LOCAL_PORT}\"]"
