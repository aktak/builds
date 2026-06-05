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

# Read a single <add key="X" value="Y" /> from the CITO.config XML.
get_config_value() {
  local key="$1"
  [[ -f "$NITO_CONFIG" ]] || return 1
  sed -nE "s/.*<add[[:space:]]+key=\"$key\"[[:space:]]+value=\"([^\"]*)\".*/\1/p" \
    "$NITO_CONFIG" | head -n1
}

# Find sqlcmd inside the MSSQL container (newer mssql-tools18 first).
find_sqlcmd() {
  local p
  for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
    if docker exec "$MSSQL_NAME" test -x "$p" 2>/dev/null; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Escape single quotes for SQL string literals.
sql_quote() { printf %s "$1" | sed "s/'/''/g"; }

# Resolve sqlcmd + credentials and stash them in caller-visible globals.
load_sql_ctx() {
  SQL_LOGIN="$(get_config_value DBLogin)"
  SQL_PASSW="$(get_config_value DBPassw)"
  SQL_DBNAME="$(get_config_value DBName)"
  if [[ -z "$SQL_LOGIN" || -z "$SQL_PASSW" ]]; then
    err "Missing DBLogin/DBPassw in $NITO_CONFIG."
    return 1
  fi
  if ! SQLCMD="$(find_sqlcmd)"; then
    err "sqlcmd not found inside container '$MSSQL_NAME'."
    return 1
  fi
  # Probe the connection so callers fail loudly with the real reason instead of
  # the parsing pipelines silently swallowing sqlcmd's stderr.
  local probe_err
  probe_err="$(docker exec "$MSSQL_NAME" "$SQLCMD" \
    -S localhost -U "$SQL_LOGIN" -P "$SQL_PASSW" -C \
    -Q "SET NOCOUNT ON; SELECT 1" 2>&1 >/dev/null)" && return 0
  err "Cannot connect to '$MSSQL_NAME':"
  err "${probe_err:-<no output — container starting or not reachable>}"
  return 1
}

# Does a database exist on the server?
db_exists() {
  local db_name="$1"
  local db_name_sql
  db_name_sql="$(sql_quote "$db_name")"
  local result
  result="$(docker exec "$MSSQL_NAME" "$SQLCMD" \
    -S localhost -U "$SQL_LOGIN" -P "$SQL_PASSW" -C \
    -h -1 -W \
    -Q "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$db_name_sql') IS NULL THEN '0' ELSE '1' END" \
    2>/dev/null | awk 'NF && $0 !~ /rows affected/ {print; exit}')"
  [[ "$result" == "1" ]]
}

# Drop a database after explicitly killing any sessions still bound to it.
drop_database() {
  local victim="$1"
  load_sql_ctx || return 1
  log "Killing connections to '$victim' and dropping the database..."
  docker exec -i "$MSSQL_NAME" "$SQLCMD" \
       -S localhost -U "$SQL_LOGIN" -P "$SQL_PASSW" -C -b <<SQL
USE master;
IF DB_ID(N'$victim') IS NOT NULL
BEGIN
    DECLARE @kill nvarchar(max) = N'';
    SELECT @kill = @kill + N'KILL ' + CONVERT(nvarchar(10), session_id) + N'; '
    FROM sys.dm_exec_sessions
    WHERE database_id = DB_ID(N'$victim') AND session_id <> @@SPID;
    IF LEN(@kill) > 0 EXEC sp_executesql @kill;
    ALTER DATABASE [$victim] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$victim];
END
SQL
}

# Read the original database name from a .bak header (column 10 of RESTORE HEADERONLY).
get_bak_dbname() {
  local container_path="$1"
  local container_path_sql
  container_path_sql="$(sql_quote "$container_path")"
  docker exec "$MSSQL_NAME" "$SQLCMD" \
    -S localhost -U "$SQL_LOGIN" -P "$SQL_PASSW" -C \
    -h -1 -W -s "|" \
    -Q "SET NOCOUNT ON; RESTORE HEADERONLY FROM DISK = N'$container_path_sql'" \
    2>/dev/null \
    | awk -F'|' 'NF >= 10 {gsub(/^ +| +$/, "", $10); print $10; exit}'
}

restore_database() {
  local bak_basename="$1"
  local target_db="$2"
  local container_path="$MSSQL_BACKUP_CONTAINER_DIR/$bak_basename"

  load_sql_ctx || return 1
  if [[ -z "$target_db" ]]; then
    err "Missing target database name."
    return 1
  fi

  local container_path_sql
  container_path_sql="$(sql_quote "$container_path")"

  log "Reading file list from '$bak_basename'..."
  local filelist
  filelist="$(docker exec "$MSSQL_NAME" "$SQLCMD" \
    -S localhost -U "$SQL_LOGIN" -P "$SQL_PASSW" -C \
    -h -1 -W -s "|" \
    -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK = N'$container_path_sql'" \
    2>/dev/null \
    | awk -F'|' 'NF >= 3 && ($3=="D" || $3=="L") {print $1"|"$3}')"

  if [[ -z "$filelist" ]]; then
    err "Could not read backup file list (file unreadable or not a valid .bak?)."
    return 1
  fi

  # Build MOVE clauses redirecting each logical file into /var/opt/mssql/data.
  local moves="" logical type ext safe target logical_sql
  while IFS='|' read -r logical type; do
    [[ -z "$logical" ]] && continue
    case "$type" in
      D) ext="mdf" ;;
      L) ext="ldf" ;;
      *) ext="ndf" ;;
    esac
    safe="${logical// /_}"
    target="/var/opt/mssql/data/${target_db}_${safe}.${ext}"
    logical_sql="$(sql_quote "$logical")"
    moves+=", MOVE N'$logical_sql' TO N'$target'"
  done <<< "$filelist"
  moves="${moves#, }"

  log "Restoring '$bak_basename' into database '$target_db'..."
  if ! docker exec -i "$MSSQL_NAME" "$SQLCMD" \
       -S localhost -U "$SQL_LOGIN" -P "$SQL_PASSW" -C -b <<SQL
IF DB_ID(N'$target_db') IS NOT NULL
    ALTER DATABASE [$target_db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [$target_db]
    FROM DISK = N'$container_path_sql'
    WITH REPLACE, $moves;
IF DB_ID(N'$target_db') IS NOT NULL
    ALTER DATABASE [$target_db] SET MULTI_USER;
SQL
  then
    err "Restore failed."
    return 1
  fi

  log "Database '$target_db' restored from '$bak_basename'."
}

# List non-system databases in the SQL container (one name per line).
list_user_databases() {
  load_sql_ctx || return 1
  docker exec "$MSSQL_NAME" "$SQLCMD" \
    -S localhost -U "$SQL_LOGIN" -P "$SQL_PASSW" -C \
    -h -1 -W \
    -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name" \
    2>/dev/null | awk 'NF && $0 !~ /rows affected/'
}

prompt_list_dbs() {
  load_sql_ctx || return 1
  local raw
  raw="$(list_user_databases)" || return 1

  local -a dbs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && dbs+=( "$line" )
  done <<< "$raw"

  echo
  if (( ${#dbs[@]} == 0 )); then
    log "No user databases present."
    return 0
  fi
  log "User databases (${#dbs[@]}):"
  local d
  for d in "${dbs[@]}"; do
    printf "  - %s\n" "$d"
  done
}

prompt_set_dbname() {
  if [[ ! -f "$NITO_CONFIG" ]]; then
    err "$NITO_CONFIG not found."
    return 1
  fi

  load_sql_ctx || return 1
  local raw
  raw="$(list_user_databases)" || return 1

  local -a dbs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && dbs+=( "$line" )
  done <<< "$raw"

  if (( ${#dbs[@]} == 0 )); then
    log "No user databases present."
    return 0
  fi

  local current
  current="$(get_config_value DBName)"
  echo
  log "Current CITO.config DBName: ${current:-<unset>}"
  log "User databases:"
  local i=1 d marker
  for d in "${dbs[@]}"; do
    if [[ "$d" == "$current" ]]; then marker="  (current)"; else marker=""; fi
    printf "  %d) %s%s\n" "$i" "$d" "$marker"
    ((i++))
  done
  printf "  0) Cancel\n\n"

  local choice
  read -rp "Select database to write to CITO.config [0]: " choice
  choice="${choice:-0}"

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > ${#dbs[@]} )); then
    warn "Invalid selection."
    return 0
  fi
  if (( choice == 0 )); then
    log "Cancelled."
    return 0
  fi

  local picked picked_esc tmp
  picked="${dbs[$((choice-1))]}"
  # Escape sed replacement specials (& and \) — | is our delimiter.
  picked_esc="$(printf %s "$picked" | sed 's/[&\\|]/\\&/g')"
  tmp="$(mktemp)"
  if sed -E "s|(<add[[:space:]]+key=\"DBName\"[[:space:]]+value=\")[^\"]*(\")|\1${picked_esc}\2|" \
       "$NITO_CONFIG" > "$tmp"; then
    mv "$tmp" "$NITO_CONFIG"
    log "CITO.config DBName set to '$picked'."
    recreate_nitodev
  else
    rm -f "$tmp"
    err "Failed to update $NITO_CONFIG."
    return 1
  fi
}

prompt_delete_db() {
  load_sql_ctx || return 1
  local raw
  raw="$(list_user_databases)" || return 1

  local -a dbs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && dbs+=( "$line" )
  done <<< "$raw"

  if (( ${#dbs[@]} == 0 )); then
    log "No user databases present."
    return 0
  fi

  echo
  log "User databases:"
  local i=1 d
  for d in "${dbs[@]}"; do
    printf "  %d) %s\n" "$i" "$d"
    ((i++))
  done
  printf "  0) Cancel\n\n"

  local choice
  read -rp "Select database to DROP [0]: " choice
  choice="${choice:-0}"

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > ${#dbs[@]} )); then
    warn "Invalid selection."
    return 0
  fi
  if (( choice == 0 )); then
    log "Cancelled."
    return 0
  fi

  local victim="${dbs[$((choice-1))]}"
  local confirm
  read -rp "Really DROP database '$victim'? [y/N]: " confirm
  confirm="$(printf %s "$confirm" | tr 'A-Z' 'a-z')"
  if [[ "$confirm" != "y" ]]; then
    log "Cancelled."
    return 0
  fi

  if ! drop_database "$victim"; then
    err "Drop failed."
    return 1
  fi
  log "Database '$victim' dropped."
}

prompt_backup_db() {
  load_sql_ctx || return 1
  local raw
  raw="$(list_user_databases)" || return 1

  local -a dbs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && dbs+=( "$line" )
  done <<< "$raw"

  if (( ${#dbs[@]} == 0 )); then
    log "No user databases present."
    return 0
  fi

  echo
  log "User databases:"
  local i=1 d
  for d in "${dbs[@]}"; do
    printf "  %d) %s\n" "$i" "$d"
    ((i++))
  done
  printf "  0) Cancel\n\n"

  local choice
  read -rp "Select database to BACKUP [0]: " choice
  choice="${choice:-0}"

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > ${#dbs[@]} )); then
    warn "Invalid selection."
    return 0
  fi
  if (( choice == 0 )); then
    log "Cancelled."
    return 0
  fi

  ensure_backup_dir
  local src="${dbs[$((choice-1))]}"
  local stamp safe_name bak_name host_path container_path
  stamp="$(date +%Y%m%d_%H%M%S)"
  safe_name="${src// /_}"
  bak_name="${safe_name}_${stamp}.bak"
  host_path="$MSSQL_BACKUP_DIR/$bak_name"
  container_path="$MSSQL_BACKUP_CONTAINER_DIR/$bak_name"

  log "Backing up '$src' to $host_path..."
  if ! docker exec -i "$MSSQL_NAME" "$SQLCMD" \
       -S localhost -U "$SQL_LOGIN" -P "$SQL_PASSW" -C -b <<SQL
BACKUP DATABASE [$src]
    TO DISK = N'$container_path'
    WITH FORMAT, INIT, COMPRESSION, NAME = N'$(sql_quote "$src") full backup';
SQL
  then
    err "Backup failed."
    return 1
  fi
  log "Backup written: $host_path"
}

prompt_restore_bak() {
  ensure_backup_dir

  shopt -s nullglob
  local bak_files=( "$MSSQL_BACKUP_DIR"/*.bak )
  shopt -u nullglob

  if (( ${#bak_files[@]} == 0 )); then
    log "No .bak files in $MSSQL_BACKUP_DIR — skipping restore."
    return 0
  fi

  echo
  log "Backups available in $MSSQL_BACKUP_DIR:"
  local i=1 f
  for f in "${bak_files[@]}"; do
    printf "  %d) %s\n" "$i" "$(basename "$f")"
    ((i++))
  done
  printf "  0) Skip restore\n\n"

  local choice
  read -rp "Select backup to restore [0]: " choice
  choice="${choice:-0}"

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > ${#bak_files[@]} )); then
    warn "Invalid selection — skipping restore."
    return 0
  fi
  if (( choice == 0 )); then
    log "Skipping restore."
    return 0
  fi

  local bak_basename
  bak_basename="$(basename "${bak_files[$((choice-1))]}")"

  load_sql_ctx || return 1
  local original_name
  original_name="$(get_bak_dbname "$MSSQL_BACKUP_CONTAINER_DIR/$bak_basename")"
  local default_name="${original_name:-${SQL_DBNAME:-}}"

  local prompt_msg target_db
  if [[ -n "$default_name" ]]; then
    prompt_msg="Target database name [$default_name]: "
  else
    prompt_msg="Target database name: "
  fi
  read -rp "$prompt_msg" target_db
  target_db="${target_db:-$default_name}"
  if [[ -z "$target_db" ]]; then
    warn "No target database name — cancelled."
    return 0
  fi

  if db_exists "$target_db"; then
    warn "Database '$target_db' already exists."
    local drop_confirm
    read -rp "Drop existing '$target_db' before restoring? [y/N]: " drop_confirm
    drop_confirm="$(printf %s "$drop_confirm" | tr 'A-Z' 'a-z')"
    if [[ "$drop_confirm" != "y" ]]; then
      log "Restore cancelled — existing database left untouched."
      return 0
    fi
    if ! drop_database "$target_db"; then
      err "Could not drop existing '$target_db' — aborting restore."
      return 1
    fi
  fi

  restore_database "$bak_basename" "$target_db"
}

open_app() {
  # Use the resolved host port; fall back to reading it from the container.
  local port="${NITO_PORT:-$(get_nito_port)}"
  port="${port:-$NITO_DEFAULT_PORT}"
  local url="http://localhost:${port}/Window.aspx?QTabs=1"
  log "Opening $url ..."
  open "$url"
}

prompt_db_menu() {
  ensure_backup_dir
  while true; do
    echo
    log "SQL actions:"
    printf "  o) Open App\n"
    printf "  l) List databases\n"
    printf "  r) Restore a .bak\n"
    printf "  s) Set database in CITO.config\n"
    printf "  b) Backup a database\n"
    printf "  d) Delete a database\n"
    printf "  e) Exit (or any other key)\n\n"
    local choice choice_lc
    read -rp "Choose [o/l/s/r/b/d/e]: " choice
    choice_lc="$(printf %s "$choice" | tr 'A-Z' 'a-z')"
    # Run actions non-fatally: under `set -e` a non-zero return from a bare
    # case branch would kill the whole script (e.g. SQL not ready yet).
    case "$choice_lc" in
      l) prompt_list_dbs   || warn "List failed — is '$MSSQL_NAME' up and accepting connections?" ;;
      r) prompt_restore_bak || warn "Restore failed — is '$MSSQL_NAME' up and accepting connections?" ;;
      s) prompt_set_dbname || warn "Set database failed — is '$MSSQL_NAME' up and accepting connections?" ;;
      b) prompt_backup_db  || warn "Backup failed — is '$MSSQL_NAME' up and accepting connections?" ;;
      d) prompt_delete_db  || warn "Delete failed — is '$MSSQL_NAME' up and accepting connections?" ;;
      o) open_app          || warn "Could not open the app URL." ;;
      *) log "Leaving SQL menu."; return 0 ;;
    esac
  done
}

NITO_NAME="nito-app-dev"
NITO_IMAGE="ghcr.io/aktak/nito:dev"
NITO_APP_DIR="$HOME/nito/app-dev"
NITO_CONFIG="$NITO_APP_DIR/CITO.config"
NITO_LOG_DIR="$NITO_APP_DIR/Log"
NITO_CONTAINER_PORT=8080   # port the app listens on inside the container
NITO_DEFAULT_PORT=80       # default host port offered on first create
NITO_PORT=""               # resolved host port (asked on create / read from container)

# Read the published host port for the app from an existing container.
get_nito_port() {
  docker inspect \
    --format "{{(index (index .NetworkSettings.Ports \"${NITO_CONTAINER_PORT}/tcp\") 0).HostPort}}" \
    "$NITO_NAME" 2>/dev/null
}

# Ask which host port to publish the app on (first create only). Default 80.
prompt_nito_port() {
  local input
  read -rp "Host port to publish the app on [$NITO_DEFAULT_PORT]: " input
  input="${input:-$NITO_DEFAULT_PORT}"
  if [[ ! "$input" =~ ^[0-9]+$ ]] || (( input < 1 || input > 65535 )); then
    warn "Invalid port '$input' — using default $NITO_DEFAULT_PORT."
    input="$NITO_DEFAULT_PORT"
  fi
  NITO_PORT="$input"
}

# Make sure a host-side CITO.config exists to mount into the container. On first
# run it's written with the default below (DBServer points at the SQL container);
# afterwards the host file is the source of truth (edit it freely).
ensure_app_config() {
  mkdir -p "$NITO_APP_DIR" "$NITO_LOG_DIR"
  if [[ ! -f "$NITO_CONFIG" ]]; then
    log "Writing app config at $NITO_CONFIG..."
    cat > "$NITO_CONFIG" <<'EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<appSettings>
    <add key="DBServer" value="nito-sql2025" />
    <add key="DBName" value="dbSCHEMA" />
    <add key="DBLogin" value="sa" />
    <add key="DBPassw" value="StrongP@sswordSql2022" />
    <add key="DBBackupFolder" value="" />
</appSettings>
EOF
  fi
}

# Pull the latest image, prompting for ghcr.io credentials only if the pull
# fails (i.e. not already authenticated to the private registry).
# Print the digest + creation date of the locally resolved image so the
# version in use is always verifiable.
report_nito_image() {
  local digest created
  digest="$(docker image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' "$NITO_IMAGE" 2>/dev/null)"
  created="$(docker image inspect --format '{{.Created}}' "$NITO_IMAGE" 2>/dev/null)"
  log "Using image: ${digest:-$NITO_IMAGE} (built ${created:-unknown})"
}

pull_nito_image() {
  log "Pulling latest '$NITO_IMAGE'..."
  if docker pull "$NITO_IMAGE"; then
    report_nito_image
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

  if docker pull "$NITO_IMAGE"; then
    report_nito_image
    return 0
  fi

  # Couldn't refresh — fall back to a cached copy if one exists (e.g. offline).
  if docker image inspect "$NITO_IMAGE" >/dev/null 2>&1; then
    warn "############################################################"
    warn "# COULD NOT FETCH THE LATEST '$NITO_IMAGE'."
    warn "# Continuing with the OLD locally cached image — it may be"
    warn "# OUTDATED. Fix connectivity/ghcr.io auth and rerun to update."
    warn "############################################################"
    report_nito_image
    return 0
  fi
  err "Unable to obtain image '$NITO_IMAGE'."
  return 1
}

run_nitodev() {
  ensure_app_config
  : "${NITO_PORT:=$NITO_DEFAULT_PORT}"
  docker run -d --name "$NITO_NAME" \
    --network "$NET_NAME" \
    -p "${NITO_PORT}:${NITO_CONTAINER_PORT}" \
    -v "$NITO_CONFIG:/app/CITO.config" \
    -v "$NITO_LOG_DIR:/app/Log" \
    "$NITO_IMAGE"
  log "Container '$NITO_NAME' created and started on host port $NITO_PORT."
}

recreate_nitodev() {
  # App caches CITO.config at startup, so a host-side edit needs a fresh
  # container to take effect. Drop + recreate (cheap; no image pull).
  if docker ps -a --format '{{.Names}}' | grep -qx "$NITO_NAME"; then
    # Preserve the port the container was created with — don't re-ask.
    NITO_PORT="$(get_nito_port)"
    [[ -z "$NITO_PORT" ]] && NITO_PORT="$NITO_DEFAULT_PORT"
    log "Recreating '$NITO_NAME' to apply CITO.config changes..."
    docker rm -f "$NITO_NAME" >/dev/null
  fi
  run_nitodev
  connect_network "$NITO_NAME"
}

ensure_nitodev() {
  # Always fetch the latest image first, then make the container match it.
  pull_nito_image || return 1

  local latest_img
  latest_img="$(docker image inspect --format '{{.Id}}' "$NITO_IMAGE")"

  if docker ps -a --format '{{.Names}}' | grep -qx "$NITO_NAME"; then
    # Container exists — reuse its published host port (don't ask).
    NITO_PORT="$(get_nito_port)"
    [[ -z "$NITO_PORT" ]] && NITO_PORT="$NITO_DEFAULT_PORT"
    log "Container '$NITO_NAME' is published on host port $NITO_PORT."

    local current_img
    current_img="$(docker inspect --format '{{.Image}}' "$NITO_NAME")"
    if [[ "$current_img" != "$latest_img" ]]; then
      log "Newer image pulled. Recreating '$NITO_NAME'..."
      docker rm -f "$NITO_NAME"
      run_nitodev
      return 0
    fi
    if docker ps --format '{{.Names}}' | grep -qx "$NITO_NAME"; then
      log "Container '$NITO_NAME' is already running on the latest image."
    else
      log "Container '$NITO_NAME' is up to date but stopped. Starting it..."
      docker start "$NITO_NAME"
    fi
    connect_network "$NITO_NAME"
    return 0
  fi

  # First create — ask which host port to publish on (default 80).
  log "Container '$NITO_NAME' not found. Creating it from $NITO_IMAGE..."
  prompt_nito_port
  run_nitodev
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
  ensure_app_config
  ensure_mssql2025
  ensure_nitodev
  prompt_db_menu
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
  ensure_app_config
  ensure_mssql2025
  ensure_nitodev
  prompt_db_menu
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
ensure_app_config
ensure_mssql2025
ensure_nitodev
prompt_db_menu
