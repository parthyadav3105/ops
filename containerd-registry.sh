#!/bin/bash
# Configure a containerd registry mirror and/or credentials on this node.
# Writes /etc/containerd/certs.d/<registry>/hosts.toml. Safe to re-run.

set -euo pipefail

CERTS_D="/etc/containerd/certs.d"

usage() {
cat <<'EOF'
Usage:
  containerd-registry.sh <registry> [--mirror URL] [-u USER [-p PASS | --password-stdin]]
  containerd-registry.sh <registry> --remove

<registry> is the name used in image references: docker.io, quay.io,
registry.k8s.io, harbor.example.com, myreg.local:5000 ...
Prefix it (or the mirror URL) with http:// for a registry without TLS.

Examples:
  # pull docker.io images through a Harbor proxy-cache project
  containerd-registry.sh docker.io --mirror harbor.example.com/dockerhub-proxy -u myuser

  # credentials for a private registry, like 'docker login'
  containerd-registry.sh harbor.example.com -u myuser

  # undo
  containerd-registry.sh docker.io --remove

Credentials are sent as a static Basic header, so the registry (or mirror) must
accept Basic auth on pulls. Harbor does; Docker Hub, GHCR and Quay do not - put
credentials on a mirror for those.
EOF
exit "${1:-1}"
}

die()  { echo "❌ $*" >&2; exit 1; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m" >&2; }

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
for c in curl base64; do command -v "$c" >/dev/null || die "$c is not installed"; done

[[ $# -eq 0 ]] && usage
[[ "$1" == "-h" || "$1" == "--help" ]] && usage 0
[[ "$1" == -* ]] && die "first argument must be the registry, e.g. docker.io (got $1)"

# Accept https://docker.io/ and similar; Docker Hub aliases all mean docker.io.
# A leading http:// marks a registry without TLS.
SCHEME="https"; [[ "$1" == http://* ]] && SCHEME="http"
REGISTRY="${1#*://}"; REGISTRY="${REGISTRY%%/*}"; shift
case "$REGISTRY" in
  index.docker.io|registry-1.docker.io|registry.hub.docker.com) REGISTRY="docker.io" ;;
esac
[[ "$REGISTRY" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "invalid registry name: $REGISTRY"

MIRROR="" USERNAME="" PASSWORD="" PASSWORD_STDIN=0 REMOVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mirror)         [[ $# -ge 2 ]] || die "--mirror needs a URL"; MIRROR="$2"; shift 2 ;;
    -u|--username)    [[ $# -ge 2 ]] || die "$1 needs a value"; USERNAME="$2"; shift 2 ;;
    -p|--password)    [[ $# -ge 2 ]] || die "$1 needs a value"; PASSWORD="$2"; shift 2 ;;
    --password-stdin) PASSWORD_STDIN=1; shift ;;
    --remove)         REMOVE=1; shift ;;
    -h|--help)        usage 0 ;;
    *)                die "unknown option: $1 (see --help)" ;;
  esac
done

DIR="$CERTS_D/$REGISTRY"

if [[ $REMOVE -eq 1 ]]; then
  [[ -z "$MIRROR$USERNAME$PASSWORD" && $PASSWORD_STDIN -eq 0 ]] || die "--remove takes no other options"
  if $SUDO test -e "$DIR"; then
    $SUDO rm -rf "$DIR"
    echo "✔ removed $DIR - $REGISTRY no longer uses a mirror or stored credentials"
  else
    echo "nothing to remove: $DIR does not exist"
  fi
  exit 0
fi

[[ -z "$PASSWORD" && $PASSWORD_STDIN -eq 0 || -n "$USERNAME" ]] || die "a password needs -u USER"
[[ -n "$MIRROR" || -n "$USERNAME" ]] || die "nothing to do: give --mirror and/or -u (see --help)"
[[ -n "$PASSWORD" && $PASSWORD_STDIN -eq 1 ]] && die "use either -p or --password-stdin, not both"

# Docker Hub images are named docker.io but served from registry-1.docker.io.
SERVER="$SCHEME://$REGISTRY"
[[ "$REGISTRY" == "docker.io" ]] && SERVER="https://registry-1.docker.io"

# Mirror: add https:// if missing. A path (e.g. a Harbor proxy project) is used
# as-is by containerd, so it must carry the /v2 API prefix.
if [[ -n "$MIRROR" ]]; then
  [[ "$MIRROR" =~ ^https?:// ]] || MIRROR="https://$MIRROR"
  MIRROR="${MIRROR%/}"
  [[ "$MIRROR" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] || die "invalid mirror URL: $MIRROR"
  BASE="$(echo "$MIRROR" | grep -oE '^https?://[^/]+')"
  MPATH="${MIRROR#"$BASE"}"
  [[ -n "$MPATH" && "$MPATH" != /v2 && "$MPATH" != /v2/* ]] && MIRROR="$BASE/v2$MPATH"
fi
HOST="${MIRROR:-$SERVER}"
BASE="$(echo "$HOST" | grep -oE '^https?://[^/]+')"
[[ "$HOST" != "$BASE" ]] && OVERRIDE_PATH=1 || OVERRIDE_PATH=0

CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/v2/" || true)"
if [[ "$CODE" == "000" ]]; then
  [[ "$BASE" == https://* ]] && [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${BASE#https://}/v2/" || true)" != "000" ]] \
    && die "${BASE#https://} has no TLS (plain HTTP) - write it as http://${BASE#https://}"
  die "cannot reach $BASE"
fi

AUTH=""
if [[ -n "$USERNAME" ]]; then
  [[ "$HOST" == "https://registry-1.docker.io" ]] && die "Docker Hub only accepts token auth; containerd cannot use static credentials for it.
   Use a mirror that holds the Docker Hub login instead, e.g.:
   containerd-registry.sh docker.io --mirror harbor.example.com/dockerhub-proxy -u <harbor-user>"

  if [[ $PASSWORD_STDIN -eq 1 ]]; then
    read -r PASSWORD || true
  elif [[ -n "$PASSWORD" ]]; then
    warn "Using --password on the command line is insecure. Use --password-stdin."
  else
    read -rsp "Password for $USERNAME@${BASE#*://}: " PASSWORD; echo
  fi
  [[ -n "$PASSWORD" ]] || die "empty password"

  # Fail now on bad credentials rather than later as ImagePullBackOff.
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "$USERNAME:$PASSWORD" "$BASE/v2/" || true)"
  case "$CODE" in
    200) ;;
    401) die "${BASE#*://} rejected the credentials for $USERNAME (or it only accepts token auth)" ;;
    *)   die "could not verify credentials against $BASE/v2/ (HTTP $CODE)" ;;
  esac
  AUTH="$(printf '%s:%s' "$USERNAME" "$PASSWORD" | base64 -w0)"
fi

# Through a mirror, fetch a well-known image's manifest the way containerd will.
if [[ -n "$MIRROR" ]]; then
  case "$REGISTRY" in
    docker.io)       PROBE="library/alpine:latest" ;;
    registry.k8s.io) PROBE="pause:3.10" ;;
    quay.io)         PROBE="prometheus/busybox:latest" ;;
    *)               PROBE="" ;;
  esac
  if [[ -n "$PROBE" ]]; then
    PREFIX="$HOST"; [[ $OVERRIDE_PATH -eq 0 ]] && PREFIX="$HOST/v2"
    ARGS=(-s -o /dev/null -w '%{http_code}' --max-time 15 -I
          -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json')
    [[ -n "$AUTH" ]] && ARGS+=(-H "Authorization: Basic $AUTH")
    CODE="$(curl "${ARGS[@]}" "$PREFIX/${PROBE%%:*}/manifests/${PROBE##*:}?ns=$REGISTRY" || true)"
    case "$CODE" in
      200) ;;
      401) [[ -n "$AUTH" ]] && die "mirror refused $REGISTRY/$PROBE at $HOST - check the mirror path (Harbor proxy project name?)"
           die "mirror refused $REGISTRY/$PROBE: it needs credentials (add -u USER)" ;;
      404) die "mirror has no $REGISTRY/$PROBE at $HOST - check the mirror path (Harbor proxy project name?)" ;;
      *)   warn "could not fetch $REGISTRY/$PROBE through the mirror (HTTP $CODE); writing the config anyway" ;;
    esac
  fi
fi

$SUDO mkdir -p "$DIR"
{
  echo "server = \"$SERVER\""
  echo ""
  echo "[host.\"$HOST\"]"
  echo "  capabilities = [\"pull\", \"resolve\"]"
  [[ $OVERRIDE_PATH -eq 1 ]] && echo "  override_path = true"
  if [[ -n "$AUTH" ]]; then
    echo "  [host.\"$HOST\".header]"
    echo "    Authorization = \"Basic $AUTH\""
  fi
} | $SUDO tee "$DIR/hosts.toml" >/dev/null
$SUDO chmod 600 "$DIR/hosts.toml"

echo "✔ wrote $DIR/hosts.toml"
if [[ -n "$MIRROR" ]]; then
  echo "  $REGISTRY → $HOST${USERNAME:+ (as $USERNAME)}"
else
  echo "  $REGISTRY: credentials for $USERNAME"
fi
echo "  Test: sudo crictl pull $REGISTRY/${PROBE:-<image>}"


