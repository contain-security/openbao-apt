#!/usr/bin/env bash
#
# test-local.sh — end-to-end local verification of the apt repo, with NO push and NO real
# signing key. Generates a throwaway key, builds ./public with publish.sh, serves it over
# HTTP, then (if docker is available) installs openbao inside a clean Ubuntu container to
# prove apt signature verification + package resolution work.
#
# Usage:
#   scripts/test-local.sh                 # full run (1 version, both arches+pkgs)
#   KEEP_VERSIONS=2 scripts/test-local.sh # keep more versions
#
# Honors the same env knobs as publish.sh (ARCHES, PACKAGES, KEEP_VERSIONS, …).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8087}"
PUBLIC_DIR="$REPO_ROOT/public"
export PUBLIC_DIR
export KEEP_VERSIONS="${KEEP_VERSIONS:-1}"
export BASE_URL="http://127.0.0.1:${PORT}"

for bin in reprepro gpg curl jq python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing tool: $bin" >&2; exit 1; }
done

# --- throwaway signing key in an isolated keyring --------------------------
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; chmod 700 "$GNUPGHOME"
cleanup() { [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$GNUPGHOME"; }
trap cleanup EXIT

echo "==> Generating throwaway signing key…"
gpg --batch --quiet --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 3072
Key-Usage: sign
Name-Real: openbao-apt local test
Name-Email: test@localhost
Expire-Date: 0
%commit
EOF
export GPG_KEY_ID="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"

# --- build the repo --------------------------------------------------------
rm -rf "$PUBLIC_DIR"
echo "==> Building apt repo into $PUBLIC_DIR (KEEP_VERSIONS=$KEEP_VERSIONS)…"
"$REPO_ROOT/scripts/publish.sh"

echo "==> reprepro integrity check…"
reprepro -b "$PUBLIC_DIR" check stable
reprepro -b "$PUBLIC_DIR" list stable

# --- serve over HTTP -------------------------------------------------------
echo "==> Serving $PUBLIC_DIR on :$PORT…"
( cd "$PUBLIC_DIR" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
HTTP_PID=$!
sleep 1
curl -fsS "http://127.0.0.1:$PORT/dists/stable/InRelease" >/dev/null \
  && echo "    InRelease reachable ✓"

# --- container install test (optional) -------------------------------------
if command -v docker >/dev/null 2>&1; then
  echo "==> Verifying install inside clean Ubuntu container…"
  docker run --rm --network host ubuntu:24.04 bash -c "
    set -e
    apt-get update -qq && apt-get install -y -qq curl ca-certificates gnupg >/dev/null
    curl -fsSL http://127.0.0.1:$PORT/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openbao-cs.gpg
    echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/openbao-cs.gpg] http://127.0.0.1:$PORT stable main' \
      > /etc/apt/sources.list.d/openbao-cs.list
    apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/openbao-cs.list \
                   -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
    apt-get install -y --download-only openbao
    echo 'CONTAINER INSTALL TEST: PASS'
  "
else
  echo "==> docker not found — skipping container install test."
  echo "    Repo built & signed; serve $PUBLIC_DIR and point an Ubuntu host at $BASE_URL to test."
fi

echo "==> Local test complete."
