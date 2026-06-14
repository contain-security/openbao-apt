#!/usr/bin/env bash
#
# setup-signing.sh — bootstrap the repo signing key using an offline-master model (run by
# a maintainer). You keep the MASTER key in your own GPG keyring; only a signing-only
# SUBKEY is ever exported to GitHub Actions.
#
#   master key  [C]  -> stays in YOUR keyring (this machine). Never sent to GitHub.
#   signing key [S]  -> exported (secret) to the GPG_PRIVATE_KEY Actions secret for CI.
#
# If the CI subkey is ever exposed, you revoke just that subkey with your master and
# re-publish — the master identity is unaffected. (Verified: reprepro signs `InRelease`
# with the subkey alone; the master secret is absent in CI.)
#
# The key is generated into YOUR real keyring (default $GNUPGHOME / ~/.gnupg) and is NOT
# deleted afterwards — you hold and control the master. Override the location by exporting
# GNUPGHOME before running if you keep a dedicated keyring.
#
# Usage:
#   scripts/setup-signing.sh [--repo contain-security/openbao-apt]
#                            [--name "..."] [--email "..."] [--keylength 4096] [--no-push]
#
#   --no-push   generate the key and write pubkey.gpg, but DON'T touch GitHub. Prints the
#               exact `gh secret set` commands so you can review/run them yourself.
#
# Prereqs: gpg; gh (authenticated) unless --no-push.
set -euo pipefail

REPO="contain-security/openbao-apt"
NAME="contain-security OpenBao apt signing key"
EMAIL="openbao-apt@contain.security"
KEYLEN=4096
PUSH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2;;
    --name)      NAME="$2"; shift 2;;
    --email)     EMAIL="$2"; shift 2;;
    --keylength) KEYLEN="$2"; shift 2;;
    --no-push)   PUSH=0; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

command -v gpg >/dev/null || { echo "gpg not found" >&2; exit 1; }
if [ "$PUSH" = 1 ]; then
  command -v gh >/dev/null || { echo "gh (GitHub CLI) not found; or use --no-push" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "run 'gh auth login' first (or use --no-push)" >&2; exit 1; }
fi

echo "==> Keyring in use: ${GNUPGHOME:-$HOME/.gnupg}  (your master key will live here)"
echo "==> Generating master [C] + signing subkey [S], RSA $KEYLEN, no passphrase…"

# Passphrase-less generation so the exported CI subkey is non-interactive. You can (and
# should) add a passphrase to the MASTER afterwards — see the printed next steps. The CI
# subkey is exported BEFORE that, so the GitHub copy stays passphrase-less and unaffected.
GEN_OUT="$(gpg --batch --status-fd 1 --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: $KEYLEN
Key-Usage: cert
Subkey-Type: RSA
Subkey-Length: $KEYLEN
Subkey-Usage: sign
Name-Real: $NAME
Name-Email: $EMAIL
Expire-Date: 0
%commit
EOF
)"

MASTER_FPR="$(awk '/KEY_CREATED/{print $4; exit}' <<<"$GEN_OUT")"
[ -n "$MASTER_FPR" ] || { echo "failed to capture generated key fingerprint" >&2; exit 1; }
SUBKEY_FPR="$(gpg --list-keys --with-colons "$MASTER_FPR" \
  | awk -F: '$1=="sub"{f=1;next} f&&$1=="fpr"{print $10; exit}')"
[ -n "$SUBKEY_FPR" ] || { echo "failed to find signing subkey" >&2; exit 1; }

echo "    Master  (offline, yours): $MASTER_FPR"
echo "    Subkey  (CI signs with) : $SUBKEY_FPR"

# Public key for clients + the published repo (full key incl. subkey).
gpg --batch --armor --export "$MASTER_FPR" > pubkey.gpg
echo "==> Wrote ./pubkey.gpg (full public key)"

# CI material = the signing subkey ONLY (master secret excluded). The reprepro SignWith
# value is the MASTER fingerprint; gpg automatically signs with the subkey.
export_ci_subkey() { gpg --batch --armor --export-secret-subkeys "${SUBKEY_FPR}!"; }

if [ "$PUSH" = 1 ]; then
  echo "==> Pushing to $REPO (subkey streamed directly into gh, never printed)…"
  export_ci_subkey | gh secret set GPG_PRIVATE_KEY --repo "$REPO"
  printf '%s' "$MASTER_FPR" | gh secret set GPG_KEY_ID --repo "$REPO"
  echo "    Set GPG_PRIVATE_KEY (subkey) and GPG_KEY_ID (master fpr) on $REPO."
else
  echo "==> --no-push: NOT contacting GitHub. Run these yourself to set the secrets:"
  echo
  echo "    gpg --armor --export-secret-subkeys '${SUBKEY_FPR}!' | gh secret set GPG_PRIVATE_KEY --repo $REPO"
  echo "    printf '%s' '$MASTER_FPR' | gh secret set GPG_KEY_ID --repo $REPO"
fi

cat <<NEXT

────────────────────────────────────────────────────────────────────────
You control the master key. Recommended follow-ups:

  1. Back up the MASTER secret offline (NOT to GitHub), then keep it safe:
       gpg --armor --export-secret-keys $MASTER_FPR > openbao-apt-MASTER.asc
       # move openbao-apt-MASTER.asc to offline/encrypted storage

  2. (Optional) Protect the master with a passphrase. The CI subkey copy was
     already exported above and is unaffected:
       gpg --passwd $MASTER_FPR

  3. Trigger the first publish and enable Pages:
       gh workflow run publish.yml --repo $REPO
       # Settings > Pages > Deploy from branch > gh-pages / root

To rotate the CI key later (e.g. suspected exposure), revoke the subkey with
your master, add a fresh signing subkey, and re-run with --no-push to update
the secret. The master identity stays stable.
────────────────────────────────────────────────────────────────────────
NEXT
