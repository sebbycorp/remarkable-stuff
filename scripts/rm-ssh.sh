#!/bin/sh
# SSH/SCP helper for the reMarkable using credentials from repo .env
# Usage:
#   ./scripts/rm-ssh.sh                 # interactive shell (prefers USB if up)
#   ./scripts/rm-ssh.sh 'uname -a'      # run remote command
#   ./scripts/rm-ssh.sh --wifi 'ls'     # force Wi-Fi host
#   ./scripts/rm-ssh.sh --usb 'ls'      # force USB host
#   ./scripts/rm-scp.sh is separate — or: RM_SCP=1 ./scripts/rm-ssh.sh local remote
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
set -a
. "$ROOT/.env"
set +a

FORCE=
case "${1:-}" in
  --wifi) FORCE=wifi; shift ;;
  --usb)  FORCE=usb;  shift ;;
esac

pick_host() {
  case "$FORCE" in
    wifi) echo "$RM_HOST"; return ;;
    usb)  echo "$RM_HOST_USB"; return ;;
  esac
  # Prefer USB when port 22 is open (sshd often Wi-Fi-off when dozing)
  if nc -z -w 2 "$RM_HOST_USB" 22 2>/dev/null; then
    echo "$RM_HOST_USB"
  else
    echo "$RM_HOST"
  fi
}

HOST="$(pick_host)"
USER="${RM_USER:-root}"
KEY="${RM_KEY:-$HOME/.ssh/id_diary}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15"

# Prefer key auth when available with safe perms; else password from .env
if [ -f "$KEY" ] && [ "$(stat -c %a "$KEY" 2>/dev/null || echo 777)" != "777" ]; then
  SSH_OPTS="$SSH_OPTS -i $KEY -o IdentitiesOnly=yes"
else
  ASKPASS=$(mktemp)
  chmod 700 "$ASKPASS"
  printf '%s\n' '#!/bin/sh' "echo '$RM_PASSWORD'" > "$ASKPASS"
  chmod +x "$ASKPASS"
  trap 'rm -f "$ASKPASS"' EXIT
  export DISPLAY= SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force
  SSH_OPTS="$SSH_OPTS -o PreferredAuthentications=password -o PubkeyAuthentication=no"
fi

if [ "${RM_SCP:-}" = 1 ]; then
  exec scp $SSH_OPTS "$@"
fi

if [ "$#" -eq 0 ]; then
  exec ssh $SSH_OPTS "${USER}@${HOST}"
else
  exec ssh $SSH_OPTS "${USER}@${HOST}" "$@"
fi
