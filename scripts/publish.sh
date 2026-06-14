#!/usr/bin/env bash
#
# publish.sh — sync the OpenBao apt repo under $PUBLIC_DIR with upstream GitHub Releases.
#
# This script ONLY builds/updates the published tree ($PUBLIC_DIR). It does not touch git;
# the CI workflow checks out gh-pages into $PUBLIC_DIR, runs this, then commits & pushes.
# That keeps the script side-effect-free and locally testable (see scripts/test-local.sh).
#
# Required:
#   A usable signing key, provided one of two ways:
#     - GPG_KEY_ID already imported into the active GNUPGHOME, or
#     - GPG_PRIVATE_KEY  (ASCII-armored secret key) in the environment to import.
#
# Optional env (with defaults):
#   PUBLIC_DIR=./public           where the apt repo is built
#   KEEP_VERSIONS=1               most-recent N releases to ingest. reprepro holds ONE
#                                 version per package/arch (it auto-replaces older with
#                                 newer), so the repo always serves the latest. Values >1
#                                 only matter if you want a brief overlap window.
#   ARCHES="amd64 arm64"          architectures to publish
#   PACKAGES="openbao openbao-hsm" package basenames to mirror
#   BASE_URL=https://contain-security.github.io/openbao-apt   used in the landing page
#   VERIFY_UPSTREAM=1             verify each .deb against its upstream *.deb.gpgsig
#   OPENBAO_GPG_KEY_URL=https://openbao.org/assets/openbao-gpg-pub-20240618.asc
#   MIN_VERSION=2.5.0             ignore releases below this (pre-`openbao_` naming era)
#   GH_TOKEN / GITHUB_TOKEN       optional, raises GitHub API rate limit
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_DIR="${PUBLIC_DIR:-$REPO_ROOT/public}"
KEEP_VERSIONS="${KEEP_VERSIONS:-1}"
ARCHES="${ARCHES:-amd64 arm64}"
PACKAGES="${PACKAGES:-openbao openbao-hsm}"
BASE_URL="${BASE_URL:-https://contain-security.github.io/openbao-apt}"
VERIFY_UPSTREAM="${VERIFY_UPSTREAM:-1}"
OPENBAO_GPG_KEY_URL="${OPENBAO_GPG_KEY_URL:-https://openbao.org/assets/openbao-gpg-pub-20240618.asc}"
MIN_VERSION="${MIN_VERSION:-2.5.0}"
UPSTREAM_API="https://api.github.com/repos/openbao/openbao/releases?per_page=100"
UPSTREAM_DL="https://github.com/openbao/openbao/releases/download"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for bin in reprepro gpg curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"
done

# ---- signing key ----------------------------------------------------------
if [ -z "${GPG_KEY_ID:-}" ]; then
  if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
    log "Importing signing key from GPG_PRIVATE_KEY"
    printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import
  fi
  GPG_KEY_ID="$(gpg --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
fi
[ -n "${GPG_KEY_ID:-}" ] || die "no signing key available (set GPG_KEY_ID or GPG_PRIVATE_KEY)"
log "Signing with key $GPG_KEY_ID"

# ---- prepare published tree ----------------------------------------------
mkdir -p "$PUBLIC_DIR/conf"
GPG_KEY_ID="$GPG_KEY_ID" \
  sed "s|\${GPG_KEY_ID}|$GPG_KEY_ID|g" "$REPO_ROOT/conf/distributions.tmpl" \
  > "$PUBLIC_DIR/conf/distributions"

reprepro_b() { reprepro -b "$PUBLIC_DIR" "$@"; }

# Snapshot of what is already registered: lines "pkg|arch|version"
declare -A PRESENT=()
while IFS= read -r line; do
  # format: "stable|main|amd64: openbao 2.5.4"
  arch="${line#*|main|}"; arch="${arch%%:*}"
  rest="${line#*: }"; pkg="${rest%% *}"; ver="${rest##* }"
  [ -n "$pkg" ] && PRESENT["$pkg|$arch|$ver"]=1
done < <(reprepro_b list stable 2>/dev/null || true)

# ---- upstream verification keyring ---------------------------------------
VERIFY_HOME=""
if [ "$VERIFY_UPSTREAM" = "1" ]; then
  VERIFY_HOME="$WORK/verify-gpg"; mkdir -p "$VERIFY_HOME"; chmod 700 "$VERIFY_HOME"
  if curl -fsSL "$OPENBAO_GPG_KEY_URL" -o "$WORK/openbao.asc"; then
    GNUPGHOME="$VERIFY_HOME" gpg --batch --quiet --import "$WORK/openbao.asc"
    log "Imported OpenBao release key for upstream signature verification"
  else
    die "could not fetch upstream signing key ($OPENBAO_GPG_KEY_URL); set VERIFY_UPSTREAM=0 to skip"
  fi
fi

verify_deb() {  # $1 = path to .deb ; verifies against <deb>.gpgsig fetched from $2
  local deb="$1" sigurl="$2" sig="$1.gpgsig"
  [ "$VERIFY_UPSTREAM" = "1" ] || return 0
  if ! curl -fsSL "$sigurl" -o "$sig"; then
    die "no upstream signature for $(basename "$deb") at $sigurl"
  fi
  GNUPGHOME="$VERIFY_HOME" gpg --batch --verify "$sig" "$deb" 2>/dev/null \
    || die "UPSTREAM SIGNATURE INVALID for $(basename "$deb") — refusing to publish"
}

# ---- select releases ------------------------------------------------------
log "Querying upstream releases"
AUTH=(); [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && AUTH=(-H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}")
RELEASES_JSON="$(curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" "$UPSTREAM_API")"

# tags >= MIN_VERSION, non-draft, non-prerelease, newest first, top N
mapfile -t VERSIONS < <(
  jq -r '.[] | select(.draft==false and .prerelease==false) | .tag_name' <<<"$RELEASES_JSON" \
    | sed 's/^v//' \
    | awk -v min="$MIN_VERSION" '
        function vge(a,b,  x,y,i){split(a,x,".");split(b,y,".");
          for(i=1;i<=3;i++){if((x[i]+0)>(y[i]+0))return 1; if((x[i]+0)<(y[i]+0))return 0} return 1}
        /^[0-9]+\.[0-9]+\.[0-9]+$/ && vge($0,min){print}' \
    | sort -rV | head -n "$KEEP_VERSIONS"
)
[ "${#VERSIONS[@]}" -gt 0 ] || die "no eligible releases found (>= $MIN_VERSION)"
log "Target versions: ${VERSIONS[*]}"

# ---- download + ingest ----------------------------------------------------
NEW=0
for ver in "${VERSIONS[@]}"; do
  for pkg in $PACKAGES; do
    for arch in $ARCHES; do
      if [ -n "${PRESENT[$pkg|$arch|$ver]:-}" ]; then
        continue
      fi
      fname="${pkg}_${ver}_linux_${arch}.deb"
      url="$UPSTREAM_DL/v${ver}/${fname}"
      out="$WORK/$fname"
      if ! curl -fsSL "$url" -o "$out"; then
        warn "asset not found, skipping: $fname"
        continue
      fi
      verify_deb "$out" "${url}.gpgsig"
      log "Ingesting $fname"
      reprepro_b includedeb stable "$out"
      NEW=$((NEW+1))
    done
  done
done

# ---- root assets (pubkey, landing page, jekyll opt-out) -------------------
gpg --batch --armor --export "$GPG_KEY_ID" > "$PUBLIC_DIR/pubkey.gpg"
: > "$PUBLIC_DIR/.nojekyll"

cat > "$PUBLIC_DIR/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>OpenBao apt repository (contain-security)</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:48rem;margin:3rem auto;padding:0 1rem}
pre{background:#f4f4f4;padding:1rem;overflow:auto;border-radius:6px}code{font-family:ui-monospace,monospace}</style>
<h1>OpenBao apt repository</h1>
<p><strong>Unofficial</strong>, signed apt repo mirroring
<a href="https://github.com/openbao/openbao/releases">OpenBao GitHub Releases</a>,
maintained by contain-security. Not affiliated with the OpenBao project.</p>
<h2>Setup (Ubuntu / Debian)</h2>
<pre><code>curl -fsSL ${BASE_URL}/pubkey.gpg \\
  | sudo gpg --dearmor -o /usr/share/keyrings/openbao-cs.gpg

echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openbao-cs.gpg] \\
${BASE_URL} stable main" \\
  | sudo tee /etc/apt/sources.list.d/openbao-cs.list

sudo apt update &amp;&amp; sudo apt install openbao   # or: openbao-hsm</code></pre>
<p>Suite <code>stable</code> · component <code>main</code> · arch <code>amd64</code>, <code>arm64</code>.
Packages re-signed locally only after their upstream OpenBao GPG signature is verified.</p>
HTML

log "Done. New packages ingested this run: $NEW"
reprepro_b list stable || true
