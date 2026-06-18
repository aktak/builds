#!/usr/bin/env bash
#
# install-docker.sh — Ensure Docker Desktop is installed on macOS.
# Checks for the `docker` CLI; if missing, installs Docker Desktop.
#
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

# --- Ensure the Docker daemon is running ------------------------------------
# Starts Docker Desktop if it isn't already up, then waits for the daemon.
ensure_running() {
  if docker info >/dev/null 2>&1; then
    log "Docker daemon is running."
    return 0
  fi

  log "Docker daemon isn't running. Starting Docker Desktop..."
  open -a Docker || { err "Could not launch Docker Desktop."; return 1; }

  log "Waiting for the Docker daemon to become ready..."
  for _ in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
      log "Docker daemon is now running."
      return 0
    fi
    sleep 2
  done

  err "Timed out waiting for the Docker daemon. Open Docker Desktop manually."
  return 1
}

NET_NAME="nito-network"

ensure_network() {
  if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    log "Network '$NET_NAME' already exists."
  else
    log "Creating network '$NET_NAME'..."
    docker network create "$NET_NAME"
  fi
}

# Attach an already-existing container to the network if not connected yet.
connect_network() {
  local name="$1"
  if docker inspect -f '{{range $n,$_ := .NetworkSettings.Networks}}{{$n}} {{end}}' "$name" \
       | grep -qw "$NET_NAME"; then
    log "Container '$name' is already on network '$NET_NAME'."
  else
    log "Connecting container '$name' to network '$NET_NAME'..."
    docker network connect "$NET_NAME" "$name"
  fi
}

MSSQL_NAME="nito-sql2025"
MSSQL_IMAGE="mcr.microsoft.com/mssql/server:2025-latest"
MSSQL_VOLUME="$HOME/nito/sql"
MSSQL_BACKUP_DIR="$MSSQL_VOLUME/backup"
MSSQL_BACKUP_CONTAINER_DIR="/var/opt/mssql/backup"

ensure_mssql2025() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$MSSQL_NAME"; then
    if docker ps --format '{{.Names}}' | grep -qx "$MSSQL_NAME"; then
      log "Container '$MSSQL_NAME' is already running."
    else
      log "Container '$MSSQL_NAME' exists but is stopped. Starting it..."
      docker start "$MSSQL_NAME"
    fi
    connect_network "$MSSQL_NAME"
    return 0
  fi

  log "Container '$MSSQL_NAME' not found. Creating it..."
  # Only the backup folder is persisted to the host — DB data lives inside the
  # container, so dropping it wipes databases (restore from a .bak to recover).
  ensure_backup_dir
  docker run -d --name "$MSSQL_NAME" \
    --network "$NET_NAME" \
    -e "ACCEPT_EULA=Y" \
    -e "MSSQL_SA_PASSWORD=StrongP@sswordSql2022" \
    -e "MSSQL_PID=developer" \
    -p 1433:1433 \
    -v "$MSSQL_BACKUP_DIR:$MSSQL_BACKUP_CONTAINER_DIR" \
    "$MSSQL_IMAGE"
  log "Container '$MSSQL_NAME' created and started."
}

ensure_backup_dir() {
  if [[ ! -d "$MSSQL_BACKUP_DIR" ]]; then
    log "Creating backup folder at $MSSQL_BACKUP_DIR..."
    mkdir -p "$MSSQL_BACKUP_DIR"
  fi
}

# --- smart-portal (nito-sp-dev) --------------------------------------------
SP_NAME="nito-sp-dev"
SP_IMAGE="ghcr.io/aktak/smart-portal:latest"
SP_PLATFORM="linux/amd64"    # image is published amd64-only; run under emulation on Apple Silicon
SP_APP_DIR="$HOME/nito/sp-dev"
SP_CONFIG="$SP_APP_DIR/config.json"
SP_APP_CONTAINER_PORT=8080   # web app port inside the container (matches config app_port)
SP_API_CONTAINER_PORT=5001   # OData API port inside the container (matches config api_port)
SP_APP_DEFAULT_PORT=8080     # default host port offered for the web app on first create
SP_API_DEFAULT_PORT=5001     # default host port offered for the API on first create
SP_APP_PORT=""               # resolved host port for the web app
SP_API_PORT=""               # resolved host port for the API

# Block until a container is at least running (not waiting for app readiness).
# We only need it "up" so its port mapping / inspect data become valid before we
# continue. Returns 0 once .State.Running is true, non-zero on timeout.
wait_container_running() {
  local name="$1" _
  for _ in $(seq 1 30); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  warn "Container '$name' did not reach 'running' within 30s."
  return 1
}

# Read the published host ports for the smart-portal app/api from an existing
# container (empty for a stopped container — swallow inspect errors under set -e).
get_sp_app_port() {
  docker inspect \
    --format "{{(index (index .NetworkSettings.Ports \"${SP_APP_CONTAINER_PORT}/tcp\") 0).HostPort}}" \
    "$SP_NAME" 2>/dev/null || true
}
get_sp_api_port() {
  docker inspect \
    --format "{{(index (index .NetworkSettings.Ports \"${SP_API_CONTAINER_PORT}/tcp\") 0).HostPort}}" \
    "$SP_NAME" 2>/dev/null || true
}

# Ask which host ports to publish the smart-portal web app + API on (first create only).
prompt_sp_ports() {
  local input
  read -rp "Host port to publish the smart-portal WEB APP on [$SP_APP_DEFAULT_PORT]: " input
  input="${input:-$SP_APP_DEFAULT_PORT}"
  if [[ ! "$input" =~ ^[0-9]+$ ]] || (( input < 1 || input > 65535 )); then
    warn "Invalid port '$input' — using default $SP_APP_DEFAULT_PORT."
    input="$SP_APP_DEFAULT_PORT"
  fi
  SP_APP_PORT="$input"

  read -rp "Host port to publish the smart-portal API on [$SP_API_DEFAULT_PORT]: " input
  input="${input:-$SP_API_DEFAULT_PORT}"
  if [[ ! "$input" =~ ^[0-9]+$ ]] || (( input < 1 || input > 65535 )); then
    warn "Invalid port '$input' — using default $SP_API_DEFAULT_PORT."
    input="$SP_API_DEFAULT_PORT"
  fi
  SP_API_PORT="$input"
}

# Make sure a host-side config.json exists to mount into the smart-portal
# container. On first run it's written with the default below (db_server points
# at the SQL container); afterwards the host file is the source of truth.
ensure_sp_config() {
  mkdir -p "$SP_APP_DIR"
  if [[ ! -f "$SP_CONFIG" ]]; then
    log "Writing smart-portal config at $SP_CONFIG..."
    cat > "$SP_CONFIG" <<EOF
{
  "customer": "DEV",
  "db_server": "$MSSQL_NAME",
  "db_username": "sa",
  "db_userpass": "StrongP@sswordSql2022",
  "db_name": "Sova_monitoring",
  "app_port": "$SP_APP_CONTAINER_PORT",
  "api_port": "$SP_API_CONTAINER_PORT",
  "x_api_key": "change-me-to-a-long-random-secret"
}
EOF
  fi
}

# Print the digest + creation date of the locally resolved smart-portal image.
report_sp_image() {
  local digest created
  digest="$(docker image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' "$SP_IMAGE" 2>/dev/null)"
  created="$(docker image inspect --format '{{.Created}}' "$SP_IMAGE" 2>/dev/null)"
  log "Using image: ${digest:-$SP_IMAGE} (built ${created:-unknown})"
}

# Pull the latest smart-portal image, prompting for ghcr.io credentials only if
# the pull fails (i.e. not already authenticated to the private registry).
pull_sp_image() {
  log "Pulling latest '$SP_IMAGE'..."
  if docker pull --platform "$SP_PLATFORM" "$SP_IMAGE"; then
    report_sp_image
    return 0
  fi

  warn "Pull failed — authenticating with ghcr.io..."
  read -rp  "GitHub username: " gh_user
  read -rsp "GitHub token (PAT with read:packages): " gh_token
  echo
  if [[ -z "$gh_user" || -z "$gh_token" ]]; then
    err "Username and token are required to pull from ghcr.io."
    return 1
  fi
  if ! printf '%s' "$gh_token" | docker login ghcr.io -u "$gh_user" --password-stdin; then
    unset gh_token
    err "docker login to ghcr.io failed."
    return 1
  fi
  unset gh_token

  if docker pull --platform "$SP_PLATFORM" "$SP_IMAGE"; then
    report_sp_image
    return 0
  fi

  if docker image inspect "$SP_IMAGE" >/dev/null 2>&1; then
    warn "############################################################"
    warn "# COULD NOT FETCH THE LATEST '$SP_IMAGE'."
    warn "# Continuing with the OLD locally cached image — it may be"
    warn "# OUTDATED. Fix connectivity/ghcr.io auth and rerun to update."
    warn "############################################################"
    report_sp_image
    return 0
  fi
  err "Unable to obtain image '$SP_IMAGE'."
  return 1
}

run_spdev() {
  ensure_sp_config
  : "${SP_APP_PORT:=$SP_APP_DEFAULT_PORT}"
  : "${SP_API_PORT:=$SP_API_DEFAULT_PORT}"
  docker run -d --name "$SP_NAME" \
    --platform "$SP_PLATFORM" \
    --network "$NET_NAME" \
    -p "${SP_APP_PORT}:${SP_APP_CONTAINER_PORT}" \
    -p "${SP_API_PORT}:${SP_API_CONTAINER_PORT}" \
    -v "$SP_CONFIG:/app/config.json" \
    "$SP_IMAGE"
  wait_container_running "$SP_NAME" || true
  log "Container '$SP_NAME' created and started (web ${SP_APP_PORT}->${SP_APP_CONTAINER_PORT}, api ${SP_API_PORT}->${SP_API_CONTAINER_PORT})."
}

recreate_spdev() {
  # Smart-portal caches config.json at startup, so a host-side edit needs a fresh
  # container to take effect. Drop + recreate (cheap; no image pull).
  if docker ps -a --format '{{.Names}}' | grep -qx "$SP_NAME"; then
    SP_APP_PORT="$(get_sp_app_port)"; [[ -z "$SP_APP_PORT" ]] && SP_APP_PORT="$SP_APP_DEFAULT_PORT"
    SP_API_PORT="$(get_sp_api_port)"; [[ -z "$SP_API_PORT" ]] && SP_API_PORT="$SP_API_DEFAULT_PORT"
    log "Recreating '$SP_NAME' to apply config.json changes..."
    docker rm -f "$SP_NAME" >/dev/null
  fi
  run_spdev
  connect_network "$SP_NAME"
}

ensure_spdev() {
  # Always fetch the latest image first, then make the container match it.
  pull_sp_image || return 1

  local latest_img
  latest_img="$(docker image inspect --format '{{.Id}}' "$SP_IMAGE")"

  if docker ps -a --format '{{.Names}}' | grep -qx "$SP_NAME"; then
    # Container exists — reuse its published host ports (don't ask).
    SP_APP_PORT="$(get_sp_app_port)"; [[ -z "$SP_APP_PORT" ]] && SP_APP_PORT="$SP_APP_DEFAULT_PORT"
    SP_API_PORT="$(get_sp_api_port)"; [[ -z "$SP_API_PORT" ]] && SP_API_PORT="$SP_API_DEFAULT_PORT"
    log "Container '$SP_NAME' is published on host ports web=$SP_APP_PORT api=$SP_API_PORT."

    local current_img
    current_img="$(docker inspect --format '{{.Image}}' "$SP_NAME")"
    if [[ "$current_img" != "$latest_img" ]]; then
      log "Newer image pulled. Recreating '$SP_NAME'..."
      docker rm -f "$SP_NAME"
      run_spdev
      return 0
    fi
    if docker ps --format '{{.Names}}' | grep -qx "$SP_NAME"; then
      log "Container '$SP_NAME' is already running on the latest image."
    else
      log "Container '$SP_NAME' is up to date but stopped. Starting it..."
      docker start "$SP_NAME"
      wait_container_running "$SP_NAME" || true
    fi
    connect_network "$SP_NAME"
    return 0
  fi

  # First create — ask which host ports to publish on (defaults 8080 / 5001).
  log "Container '$SP_NAME' not found. Creating it from $SP_IMAGE..."
  prompt_sp_ports
  run_spdev
}

# --- Sanity: macOS only -----------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script only supports macOS."
  exit 1
fi

# --- Already installed? -----------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  log "Docker is already installed: $(docker --version)"
  ensure_running || exit 1
  ensure_network
  ensure_mssql2025
  ensure_spdev
  exit 0
fi

log "Docker not found. Installing Docker Desktop for Mac..."

# --- Detect architecture ----------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) DMG_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg" ;;
  x86_64) DMG_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg" ;;
  *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# --- Prefer Homebrew if available ------------------------------------------
if command -v brew >/dev/null 2>&1; then
  log "Homebrew detected. Installing via 'brew install --cask docker'..."
  brew install --cask docker
  log "Install complete."
  ensure_running || exit 1
  ensure_network
  ensure_mssql2025
  ensure_spdev
  exit 0
fi

# --- Fallback: download + mount DMG manually --------------------------------
warn "Homebrew not found. Falling back to direct download (requires sudo)."

TMP_DMG="$(mktemp -t Docker).dmg"
MOUNT_POINT="$(mktemp -d -t docker-mount)"

cleanup() {
  if mount | grep -q "$MOUNT_POINT"; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -f "$TMP_DMG"
  rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

log "Downloading Docker.dmg for $ARCH..."
curl -fSL --progress-bar "$DMG_URL" -o "$TMP_DMG"

log "Mounting disk image..."
hdiutil attach "$TMP_DMG" -nobrowse -mountpoint "$MOUNT_POINT" -quiet

log "Copying Docker.app to /Applications (may prompt for your password)..."
sudo cp -R "$MOUNT_POINT/Docker.app" /Applications/

log "Running Docker first-launch install helper..."
sudo /Applications/Docker.app/Contents/MacOS/install --accept-license || \
  warn "Install helper returned non-zero; you may need to open Docker Desktop manually."

log "Docker Desktop installed."
ensure_running || exit 1
ensure_network
ensure_mssql2025
ensure_spdev
