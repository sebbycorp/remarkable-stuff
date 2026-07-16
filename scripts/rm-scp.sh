#!/bin/sh
# SCP helper using .env password auth.
# Usage:
#   ./scripts/rm-scp.sh diary root@auto:/home/root/diary
#   ./scripts/rm-scp.sh --usb localfile /home/root/remote
#   ./scripts/rm-scp.sh --from-tablet /home/root/diary.conf ./diary.conf
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
set -a
. "$ROOT/.env"
set +a

FORCE=
FROM_TABLET=
case "${1:-}" in
  --wifi) FORCE=wifi; shift ;;
  --usb)  FORCE=usb;  shift ;;
esac
case "${1:-}" in
  --from-tablet) FROM_TABLET=1; shift ;;
esac

pick_host() {
  case "$FORCE" in
    wifi) echo "$RM_HOST"; return ;;
    usb)  echo "$RM_HOST_USB"; return ;;
  esac
  if nc -z -w 2 "$RM_HOST_USB" 22 2>/dev/null; then
    echo "$RM_HOST_USB"
  else
    echo "$RM_HOST"
  fi
}

HOST="$(pick_host)"
USER="${RM_USER:-root}"

ASKPASS=$(mktemp)
chmod 700 "$ASKPASS"
printf '%s\n' '#!/bin/sh' "echo '$RM_PASSWORD'" > "$ASKPASS"
chmod +x "$ASKPASS"
trap 'rm -f "$ASKPASS"' EXIT

export DISPLAY= SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force
SSH_OPTS="-o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=15"

if [ "$FROM_TABLET" = 1 ]; then
  # ./scripts/rm-scp.sh --from-tablet /remote/path localpath
  REMOTE="$1"
  LOCAL="$2"
  exec scp $SSH_OPTS "${USER}@${HOST}:${REMOTE}" "$LOCAL"
fi

# Local → tablet: last arg is remote path on tablet
if [ "$#" -lt 2 ]; then
  echo "usage: $0 [--usb|--wifi] local... remote-path" >&2
  echo "       $0 [--usb|--wifi] --from-tablet remote-path local" >&2
  exit 1
fi
# Collect sources; last is remote dest path
i=1
srcs=
while [ "$i" -lt "$#" ]; do
  eval "s=\$$i"
  srcs="$srcs $s"
  i=$((i + 1))
done
eval "dest=\$$#"
# shellcheck disable=SC2086
exec scp $SSH_OPTS $srcs "${USER}@${HOST}:${dest}"
