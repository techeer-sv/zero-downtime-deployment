#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_IMAGE="${APP_IMAGE:-zero-downtime-app}"
APP_IMAGE_TAG="${1:-${APP_IMAGE_TAG:-${VERSION:-}}}"
DEPLOY_IMAGE="${DEPLOY_IMAGE:-}"
REPLICAS="${REPLICAS:-3}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
HEALTH_INTERVAL_SECONDS="${HEALTH_INTERVAL_SECONDS:-2}"
TRAEFIK_SETTLE_SECONDS="${TRAEFIK_SETTLE_SECONDS:-3}"
PULL_IMAGE="${PULL_IMAGE:-false}"
TARGET_COLOR="${TARGET_COLOR:-}"
export MY_OTEL_HOST="${MY_OTEL_HOST:-otel-collector}"

ROUTER_DIR="$BASE_DIR/dynamic"
ROUTER_FILE="$ROUTER_DIR/routers.yaml"
TEMPLATE_DIR="$BASE_DIR/templates"
TMP_DIR=""
candidate_started="false"
active_color=""
target_color=""

log() {
  printf '[bluegreen-deploy] %s\n' "$*"
}

fail() {
  printf '[bluegreen-deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <image-tag>

Environment:
  APP_IMAGE                 Image repository/name. Default: zero-downtime-app
  APP_IMAGE_TAG or VERSION  Image tag when no positional tag is given.
  DEPLOY_IMAGE              Full image reference. Overrides APP_IMAGE + tag.
  TARGET_COLOR              blue or green. Default: inactive color.
  REPLICAS                  Replica count. Default: 3
  PULL_IMAGE                true to docker pull before deploy. Default: false

Examples:
  bash scripts/deploy.sh v1.0.2
  APP_IMAGE=ghcr.io/acme/app bash scripts/deploy.sh sha-abc123
  DEPLOY_IMAGE=ghcr.io/acme/app:sha-abc123 bash scripts/deploy.sh
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

detect_active_color() {
  if [ ! -f "$ROUTER_FILE" ]; then
    return 0
  fi

  awk '
    /name:[[:space:]]*app-blue@docker/ { color = "blue" }
    /name:[[:space:]]*app-green@docker/ { color = "green" }
    /weight:/ {
      weight = $0
      sub(/.*weight:[[:space:]]*/, "", weight)
      if ((weight + 0) > 0 && color != "") {
        active = color
      }
    }
    END {
      if (active != "") {
        print active
      }
    }
  ' "$ROUTER_FILE"
}

service_for_color() {
  case "$1" in
    blue) printf 'app-blue' ;;
    green) printf 'app-green' ;;
    *) fail "Unknown color: $1" ;;
  esac
}

compose_file_for_color() {
  case "$1" in
    blue) printf '%s/blue.yaml' "$BASE_DIR" ;;
    green) printf '%s/green.yaml' "$BASE_DIR" ;;
    *) fail "Unknown color: $1" ;;
  esac
}

only_template_for_color() {
  case "$1" in
    blue) printf '%s/blue-only.yaml' "$TEMPLATE_DIR" ;;
    green) printf '%s/green-only.yaml' "$TEMPLATE_DIR" ;;
    *) fail "Unknown color: $1" ;;
  esac
}

write_router() {
  local color="$1"
  local template
  template="$(only_template_for_color "$color")"

  [ -f "$template" ] || fail "Router template not found: $template"
  mkdir -p "$ROUTER_DIR"
  cp "$template" "$ROUTER_FILE"
  log "Traffic now points to $color."
}

normalize_host_port() {
  local endpoint="$1"
  endpoint="${endpoint#tcp://}"
  endpoint="${endpoint/0.0.0.0:/127.0.0.1:}"
  endpoint="${endpoint/\[::\]:/127.0.0.1:}"
  printf '%s' "$endpoint"
}

healthcheck_candidate() {
  local color="$1"
  local compose_file="$2"
  local override_file="$3"
  local service
  service="$(service_for_color "$color")"

  for index in $(seq 1 "$REPLICAS"); do
    local healthy="false"

    for _ in $(seq 1 "$HEALTH_RETRIES"); do
      local endpoint=""
      endpoint="$(docker compose -f "$compose_file" -f "$override_file" port --index "$index" "$service" 8080 2>/dev/null || true)"

      if [ -n "$endpoint" ]; then
        endpoint="$(normalize_host_port "$endpoint")"
        if curl -fsS "http://$endpoint$HEALTH_PATH" >/dev/null 2>&1; then
          healthy="true"
          log "$service replica $index is healthy at http://$endpoint$HEALTH_PATH."
          break
        fi
      fi

      sleep "$HEALTH_INTERVAL_SECONDS"
    done

    [ "$healthy" = "true" ] || fail "$service replica $index failed health check."
  done
}

rollback() {
  local exit_code="$?"

  if [ "$exit_code" -ne 0 ] && [ "$candidate_started" = "true" ]; then
    log "Deployment failed. Rolling back router and stopping $target_color."

    if [ -n "$active_color" ]; then
      write_router "$active_color" || true
    fi

    docker compose -f "$(compose_file_for_color "$target_color")" down || true
  fi

  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi

  exit "$exit_code"
}

trap rollback EXIT

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

require_command docker
require_command curl
require_command awk

if [ -z "$DEPLOY_IMAGE" ]; then
  [ -n "$APP_IMAGE_TAG" ] || {
    usage
    fail "Image tag is required. Pass it as an argument or set APP_IMAGE_TAG."
  }
  DEPLOY_IMAGE="$APP_IMAGE:$APP_IMAGE_TAG"
fi

case "$TARGET_COLOR" in
  "" | blue | green) ;;
  *) fail "TARGET_COLOR must be blue or green." ;;
esac

case "$PULL_IMAGE" in
  true | false) ;;
  *) fail "PULL_IMAGE must be true or false." ;;
esac

cd "$BASE_DIR"
mkdir -p "$ROUTER_DIR"

log "Ensuring Traefik is running."
docker compose -f "$BASE_DIR/docker-compose.yaml" up -d traefik

active_color="$(detect_active_color || true)"

if [ -z "$TARGET_COLOR" ]; then
  case "$active_color" in
    blue) target_color="green" ;;
    green) target_color="blue" ;;
    "") target_color="blue" ;;
    *) fail "Unable to detect active color from $ROUTER_FILE: $active_color" ;;
  esac
else
  target_color="$TARGET_COLOR"
fi

if [ "$target_color" = "$active_color" ]; then
  fail "Target color '$target_color' is already active. Use the inactive color for blue-green deployment."
fi

target_service="$(service_for_color "$target_color")"
target_compose_file="$(compose_file_for_color "$target_color")"

[ -f "$target_compose_file" ] || fail "Compose file not found: $target_compose_file"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bluegreen-deploy.XXXXXX")"
override_file="$TMP_DIR/$target_color.override.yaml"

cat >"$override_file" <<EOF
services:
  $target_service:
    image: $DEPLOY_IMAGE
EOF

log "Active color: ${active_color:-none}. Target color: $target_color. Image: $DEPLOY_IMAGE."

if [ "$PULL_IMAGE" = "true" ]; then
  log "Pulling $DEPLOY_IMAGE."
  docker pull "$DEPLOY_IMAGE"
fi

log "Starting $target_service with $REPLICAS replicas."
docker compose -f "$target_compose_file" -f "$override_file" up -d --scale "$target_service=$REPLICAS"
candidate_started="true"

log "Checking $target_service health."
healthcheck_candidate "$target_color" "$target_compose_file" "$override_file"

log "Switching traffic to $target_color."
write_router "$target_color"
sleep "$TRAEFIK_SETTLE_SECONDS"
candidate_started="false"

if [ -n "$active_color" ]; then
  log "Stopping previous $active_color deployment."
  docker compose -f "$(compose_file_for_color "$active_color")" down
fi

log "Deployment completed successfully."
