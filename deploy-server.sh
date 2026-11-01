#!/usr/bin/env bash
# ARTOTEL MikroTik Management — production deploy over a read-only SSH deploy key.
#
# First run: generates the deploy key, waits for it to be added to GitHub,
# clones the private repository, and runs scripts/setup-linux.sh.
# Later runs: fast-forward pull and rebuild the Compose stack.
#
# The deploy key is scoped to one repository and must be added with
# "Allow write access" OFF. No GitHub token is stored on the server.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/../package.json" && -d "$SCRIPT_DIR/../backend" ]]; then
  DEFAULT_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [[ "${EUID}" -eq 0 ]]; then
  DEFAULT_REPO_DIR="/opt/artotel-mikrotik-mgmt"
else
  DEFAULT_REPO_DIR="${HOME}/artotel-mikrotik-mgmt"
fi

REPO_DIR="$DEFAULT_REPO_DIR"
REPO_URL="git@github-artotel:it-avp-bali/mikrotik-mgmt.git"
BRANCH="main"
SSH_ALIAS="github-artotel"
KEY_PATH="${HOME}/.ssh/artotel_deploy"
SSH_CONFIG="${HOME}/.ssh/config"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
ASSUME_YES=false
UPDATE_ONLY=false
CLONE_ONLY=false
KEEP_REMOTE=false
PRINT_KEY_ONLY=false
SETUP_ARGS=()

usage() {
  cat <<'EOF'
Usage: bash scripts/deploy-server.sh [options]

First run generates a read-only deploy key, prints the public key, waits until
it is added to GitHub, clones the private repository, then runs setup-linux.sh.
Later runs pull the latest commit and rebuild the Compose stack.

Options:
  --repo-dir=DIR          Clone/deploy directory (default: script parent or /opt)
  --repo-url=URL          Git remote (default: git@github-artotel:it-avp-bali/mikrotik-mgmt.git)
  --branch=NAME           Branch to deploy (default: main)
  --key=PATH              Deploy key path (default: ~/.ssh/artotel_deploy)
  --ssh-alias=NAME        SSH config alias (default: github-artotel)
  --update                Require an existing clone; pull and rebuild
  --clone-only            Clone only; do not run setup or rebuild
  --print-key             Print the deploy public key and exit
  --keep-remote           Do not rewrite an existing origin URL
  --yes, -y               Do not wait for the deploy key confirmation
  --admin-username=NAME   Forwarded to setup-linux.sh
  --admin-password=PASS   Forwarded to setup-linux.sh (prefer the interactive prompt)
  --skip-docker-install   Forwarded to setup-linux.sh
  --force-env             Forwarded to setup-linux.sh (rotates secrets)
  -h, --help              Show this help

Examples:
  sudo bash deploy-server.sh
  sudo bash /opt/artotel-mikrotik-mgmt/scripts/deploy-server.sh
  sudo bash scripts/deploy-server.sh --update
EOF
}

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --repo-dir=*) REPO_DIR="${arg#*=}" ;;
    --repo-url=*) REPO_URL="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    --key=*) KEY_PATH="${arg#*=}" ;;
    --ssh-alias=*) SSH_ALIAS="${arg#*=}" ;;
    --update) UPDATE_ONLY=true ;;
    --clone-only) CLONE_ONLY=true ;;
    --keep-remote) KEEP_REMOTE=true ;;
    --print-key) PRINT_KEY_ONLY=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --admin-username=*|--admin-password=*|--skip-docker-install|--force-env)
      SETUP_ARGS+=("$arg")
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $arg (use --help)" ;;
  esac
done

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required when not running as root."
  SUDO=(sudo)
fi

run_root() { "${SUDO[@]}" "$@"; }

ensure_packages() {
  local missing=()
  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v ssh >/dev/null 2>&1 || missing+=(openssh-client)
  command -v ssh-keygen >/dev/null 2>&1 || missing+=(openssh-client)
  command -v ssh-keyscan >/dev/null 2>&1 || missing+=(openssh-client)

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || \
    die "Missing ${missing[*]}. Install git and openssh-client, then rerun."
  log "Installing host packages: ${missing[*]}"
  run_root apt-get update -y
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

ensure_ssh_dir() {
  install -d -m 700 "${HOME}/.ssh"
  touch "$KNOWN_HOSTS" "$SSH_CONFIG"
  chmod 600 "$KNOWN_HOSTS" "$SSH_CONFIG"
}

ensure_key() {
  if [[ -f "$KEY_PATH" ]]; then
    log "Using existing deploy key: $KEY_PATH"
  else
    log "Generating a read-only deploy key: $KEY_PATH"
    install -d -m 700 "$(dirname "$KEY_PATH")"
    ssh-keygen -t ed25519 -C "artotel-deploy@$(hostname)" -f "$KEY_PATH" -N "" >/dev/null
    chmod 600 "$KEY_PATH"
    chmod 644 "$KEY_PATH.pub"
  fi
}

print_key_instructions() {
  cat <<EOF

Add this public key to GitHub now:

  Repository -> Settings -> Deploy keys -> Add deploy key
  Title:     $(hostname) artotel deploy
  Key:
$(cat "$KEY_PATH.pub")

  Allow write access: OFF (read-only)

EOF
}

wait_for_key() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi
  [[ -t 0 ]] || die "No interactive terminal. Add the key, then rerun with --yes."
  read -r -p "Press Enter after the deploy key is saved in GitHub... " _
}

ensure_known_hosts() {
  if ssh-keygen -F github.com -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    return 0
  fi
  log "Pinning github.com host keys"
  warn "Verify the fingerprint against https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints"
  local scanned
  scanned="$(ssh-keyscan -t ed25519,rsa github.com 2>/dev/null || true)"
  [[ -n "$scanned" ]] || die "Could not reach github.com to read its host key."
  printf '%s\n' "$scanned" >> "$KNOWN_HOSTS"
  sort -u "$KNOWN_HOSTS" -o "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
}

ensure_ssh_config() {
  if grep -qE "^[[:space:]]*Host[[:space:]]+${SSH_ALIAS}([[:space:]]|$)" "$SSH_CONFIG" 2>/dev/null; then
    log "SSH alias '${SSH_ALIAS}' already configured in ${SSH_CONFIG}"
    return 0
  fi
  log "Adding SSH alias '${SSH_ALIAS}' to ${SSH_CONFIG}"
  cat >> "$SSH_CONFIG" <<EOF

Host ${SSH_ALIAS}
  HostName github.com
  User git
  IdentityFile ${KEY_PATH}
  IdentitiesOnly yes
EOF
  chmod 600 "$SSH_CONFIG"
}

SSH_CHECK_OUTPUT=""

ssh_check() {
  local output rc
  set +e
  output="$(ssh -o BatchMode=yes -o ConnectTimeout=15 -T "git@${SSH_ALIAS}" 2>&1)"
  rc=$?
  set -e

  if [[ "$output" == *"successfully authenticated"* ]]; then
    return 0
  fi

  SSH_CHECK_OUTPUT="$output (exit ${rc})"
  return 1
}

ensure_ssh_access() {
  log "Testing the deploy key against GitHub"
  if ssh_check; then
    log "Deploy key accepted by GitHub"
    return 0
  fi

  print_key_instructions
  wait_for_key
  if ssh_check; then
    log "Deploy key accepted by GitHub"
    return 0
  fi

  printf '%s\n' "$SSH_CHECK_OUTPUT" >&2
  die "GitHub rejected the deploy key. Add the key to this repository with read access, then rerun."
}

require_clean_tree() {
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]]; then
    die "Working tree in ${REPO_DIR} has local changes. Commit or stash them before deploying."
  fi
}

ensure_remote() {
  local current
  current="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"

  if [[ -z "$current" ]]; then
    git -C "$REPO_DIR" remote add origin "$REPO_URL"
  elif [[ "$current" != "$REPO_URL" && "$KEEP_REMOTE" != "true" ]]; then
    warn "origin is ${current}; switching to ${REPO_URL} so the deploy key is used"
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  fi
}

clone_repo() {
  if [[ -d "$REPO_DIR" && -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]]; then
    die "${REPO_DIR} exists and is not empty. Remove it or pass --repo-dir=DIR."
  fi

  log "Cloning ${REPO_URL} (${BRANCH}) into ${REPO_DIR}"
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$REPO_DIR"
}

pull_repo() {
  require_clean_tree
  ensure_remote
  log "Fetching origin/${BRANCH}"
  git -C "$REPO_DIR" fetch --prune origin "$BRANCH"
  git -C "$REPO_DIR" checkout "$BRANCH" >/dev/null 2>&1 || \
    die "Could not check out ${BRANCH} in ${REPO_DIR}."
  git -C "$REPO_DIR" merge --ff-only "origin/${BRANCH}"
}

ensure_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif "${SUDO[@]}" docker info >/dev/null 2>&1; then
    DOCKER=("${SUDO[@]}" docker)
  else
    die "Docker daemon is not reachable. Run scripts/setup-linux.sh first."
  fi
  "${DOCKER[@]}" compose version >/dev/null 2>&1 || \
    die "Docker Compose v2 is required."
}

wait_for_backend() {
  log "Waiting for backend health"
  local container status
  for _ in $(seq 1 60); do
    container="$(cd "$REPO_DIR" && "${DOCKER[@]}" compose ps -q backend 2>/dev/null || true)"
    if [[ -n "$container" ]]; then
      status="$("${DOCKER[@]}" inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container" 2>/dev/null || true)"
      if [[ "$status" == "healthy" ]]; then
        log "Backend is healthy"
        return 0
      fi
    fi
    sleep 2
  done
  ( cd "$REPO_DIR" && "${DOCKER[@]}" compose logs --tail=100 backend ) || true
  die "Backend did not become healthy in time."
}

run_setup() {
  log "Running first-time server setup (scripts/setup-linux.sh)"
  ( cd "$REPO_DIR" && bash scripts/setup-linux.sh "${SETUP_ARGS[@]}" )
}

rebuild() {
  ensure_docker
  log "Rebuilding and restarting the Compose stack"
  ( cd "$REPO_DIR" && "${DOCKER[@]}" compose build --pull && "${DOCKER[@]}" compose up -d )
  wait_for_backend
}

print_summary() {
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  cat <<EOF

Deployment directory: ${REPO_DIR}
Repository:           ${REPO_URL} (${BRANCH})
Deploy key:           ${KEY_PATH} (read-only, repository-scoped)

Open:  https://localhost
EOF
  if [[ -n "${host_ip:-}" ]]; then
    echo "LAN:   https://${host_ip}"
  fi
  echo
  echo "Next deploys: sudo bash ${REPO_DIR}/scripts/deploy-server.sh --update"
  echo "Back up .env and certs/server.key to encrypted offline storage."
}

ensure_packages
ensure_ssh_dir
ensure_key

if [[ "$PRINT_KEY_ONLY" == "true" ]]; then
  cat "$KEY_PATH.pub"
  exit 0
fi

ensure_known_hosts
ensure_ssh_config

if [[ "$UPDATE_ONLY" == "true" && ! -d "$REPO_DIR/.git" ]]; then
  die "--update requires an existing clone at ${REPO_DIR}. Run without --update first."
fi

if [[ "$REPO_URL" == git@* ]]; then
  ensure_ssh_access
fi

if [[ -d "$REPO_DIR/.git" ]]; then
  pull_repo
else
  clone_repo
fi

if [[ "$CLONE_ONLY" == "true" ]]; then
  log "Clone complete (setup skipped because of --clone-only)"
  print_summary
  exit 0
fi

if [[ -f "$REPO_DIR/.env" && -f "$REPO_DIR/certs/server.crt" && -f "$REPO_DIR/certs/server.key" ]]; then
  rebuild
else
  run_setup
fi

print_summary
