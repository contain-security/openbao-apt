#!/usr/bin/env bash
#
# rotate-signing-key.sh — rotate the CI signing SUBKEY under your existing master key.
#
# Offline-master model (see setup-signing.sh): the master key [C] stays yours; only a
# signing subkey [S] is used by CI. Rotation = add a fresh signing subkey, (optionally)
# revoke the old one, re-export the public key, and update the GitHub secret. The master
# fingerprint never changes, so the apt source line and `SignWith` stay the same.
#
# This script is deliberately paranoid: it VERIFIES the postcondition of every step and
# aborts loudly (naming the step) if reality doesn't match, and it runs a sign+verify
# self-test with the NEW subkey before pushing anything. No surprise GPG dialogs: it asks
# for your master passphrase up-front (its own prompt) and drives gpg with --pinentry-mode
# loopback (passphrase fed on a private fd, never on argv), so pinentry never pops a window.
#
# It MODIFIES your real keyring (default $GNUPGHOME / ~/.gnupg): adds a subkey and, unless
# --keep-old, revokes the previous signing subkey(s). The master secret must be present in
# the keyring (re-import your offline backup first if you keep it offline).
#
# Usage:
#   scripts/rotate-signing-key.sh [options]
#     --repo OWNER/REPO     default contain-security/openbao-apt
#     --master FPR          master fingerprint (else auto-detected by --identity match)
#     --identity STR        uid substring used to auto-detect the master (default: openbao-apt)
#     --keylength N         new subkey RSA length (default 4096)
#     --expire SPEC         new subkey expiry, gpg syntax e.g. 2y, 0 = never (default 0)
#     --compromised         revoke old subkey with reason "compromised" (default: "superseded")
#     --keep-old            add the new subkey but DON'T revoke the old one(s)
#     --no-push             don't touch GitHub; print the `gh secret set` command instead
#     --yes                 skip the interactive confirmation
#
# Prereqs: gpg (2.4+); gh (authenticated) unless --no-push.
set -euo pipefail

REPO="contain-security/openbao-apt"
MASTER_FPR=""
IDENTITY="openbao-apt"
KEYLEN=4096
EXPIRE=0
REASON_CODE=2                       # gpg revocation reason: 2 = superseded, 1 = compromised
REASON_TEXT="Superseded by rotated OpenBao apt signing subkey"
KEEP_OLD=0
PUSH=1
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO="$2"; shift 2;;
    --master)      MASTER_FPR="$2"; shift 2;;
    --identity)    IDENTITY="$2"; shift 2;;
    --keylength)   KEYLEN="$2"; shift 2;;
    --expire)      EXPIRE="$2"; shift 2;;
    --compromised) REASON_CODE=1; REASON_TEXT="Signing subkey compromised; rotated"; shift;;
    --keep-old)    KEEP_OLD=1; shift;;
    --no-push)     PUSH=0; shift;;
    --yes)         ASSUME_YES=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

c_blue=$'\033[1;34m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_green=$'\033[1;32m'; c_off=$'\033[0m'
step() { printf '%s==> %s%s\n' "$c_blue" "$*" "$c_off"; }
ok()   { printf '%s    OK %s%s\n' "$c_green" "$*" "$c_off"; }
warn() { printf '%sWARN: %s%s\n' "$c_yellow" "$*" "$c_off" >&2; }
die()  { printf '%sERROR (%s): %s%s\n' "$c_red" "${CURRENT_STEP:-init}" "$*" "$c_off" >&2; exit 1; }

command -v gpg >/dev/null || die "gpg not found"
if [ "$PUSH" = 1 ]; then
  command -v gh >/dev/null || die "gh (GitHub CLI) not found; or use --no-push"
  gh auth status >/dev/null 2>&1 || die "run 'gh auth login' first (or use --no-push)"
fi

# gpg driven with loopback pinentry; the master passphrase is fed on fd 3 (never on argv,
# so it can't leak via `ps` and can't trip secret scanners). MASTER_PP is set below.
MASTER_PP=""
gpgm() { gpg --pinentry-mode loopback --passphrase-fd 3 "$@" 3<<<"$MASTER_PP"; }

# List signing-capable subkeys as "fpr validity" (validity 'r' = revoked, 'e' = expired).
sign_subs() {
  gpg --list-keys --with-colons "$MASTER_FPR" | awk -F: '
    $1=="sub"{v=$2; u=$12; s=1; next}
    s && $1=="fpr"{ if (index(u,"s")) print $10, v; s=0 }'
}
# fingerprints of currently-VALID signing subkeys (not revoked/expired)
valid_sign_subs() { sign_subs | awk '$2!="r" && $2!="e"{print $1}'; }

# ---- resolve & validate the master key ------------------------------------
CURRENT_STEP="resolve-master"
if [ -z "$MASTER_FPR" ]; then
  step "Auto-detecting master key (secret key whose uid contains '$IDENTITY')…"
  mapfile -t CAND < <(
    gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: -v id="$IDENTITY" '
      $1=="sec"{fpr=""; have=0}
      $1=="fpr" && fpr==""{fpr=$10}
      $1=="uid" && !have && index($10,id){ print fpr; have=1 }')
  CAND=($(printf '%s\n' "${CAND[@]}" | grep -v '^$' | sort -u))
  [ "${#CAND[@]}" -eq 1 ] || die "expected exactly 1 matching master key, found ${#CAND[@]}. Pass --master FPR."
  MASTER_FPR="${CAND[0]}"
fi
gpg --list-keys "$MASTER_FPR" >/dev/null 2>&1 || die "master key $MASTER_FPR not in keyring"

# master SECRET must be present (line 'sec', not 'sec#')
SEC_LINE="$(gpg --list-secret-keys --with-colons "$MASTER_FPR" 2>/dev/null | awk -F: '/^sec/{print $1; exit}')"
[ "$SEC_LINE" = "sec" ] || die "master SECRET not available (got '${SEC_LINE:-none}'). Re-import your offline master backup first:
    gpg --import openbao-apt-MASTER.asc"
ok "Master: $MASTER_FPR (secret present)"

OLD_VALID=($(valid_sign_subs))
step "Plan"
echo "    Keyring     : ${GNUPGHOME:-$HOME/.gnupg}"
echo "    Master      : $MASTER_FPR"
echo "    Add subkey  : RSA $KEYLEN, expire=$EXPIRE"
if [ "$KEEP_OLD" = 1 ]; then
  echo "    Old subkeys : KEPT (not revoked): ${OLD_VALID[*]:-none}"
else
  echo "    Revoke old  : ${OLD_VALID[*]:-none}  (reason: $REASON_TEXT)"
fi
echo "    GitHub push : $([ "$PUSH" = 1 ] && echo "yes -> $REPO" || echo "no (--no-push)")"

if [ "$ASSUME_YES" != 1 ]; then
  printf 'Proceed? This modifies your keyring. [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "aborted."; exit 0;; esac
fi

# ---- master passphrase (our own prompt; no GPG GUI) -----------------------
CURRENT_STEP="passphrase"
printf 'Enter your MASTER key passphrase (leave blank if the key has none): '
read -rs MASTER_PP; echo

# ---- 1. add a fresh signing subkey ----------------------------------------
CURRENT_STEP="add-subkey"
step "Adding new signing subkey…"
gpgm --batch --quick-add-key "$MASTER_FPR" "rsa${KEYLEN}" sign "$EXPIRE" \
  || die "quick-add-key failed (wrong passphrase? master secret absent?)"
NEW_SUBKEY=""
for f in $(valid_sign_subs); do
  skip=0; for o in "${OLD_VALID[@]:-}"; do [ "$f" = "$o" ] && skip=1; done
  [ "$skip" = 0 ] && NEW_SUBKEY="$f"
done
[ -n "$NEW_SUBKEY" ] || die "no new signing subkey detected after add"
ok "New signing subkey: $NEW_SUBKEY"

# ---- 2. revoke previous signing subkey(s) ---------------------------------
if [ "$KEEP_OLD" = 1 ]; then
  warn "Keeping old signing subkey(s) valid (--keep-old). CI will still sign with the newest."
else
  CURRENT_STEP="revoke-old"
  for OLD in "${OLD_VALID[@]:-}"; do
    [ -n "$OLD" ] || continue
    step "Revoking old signing subkey $OLD…"
    gpgm --command-fd 0 --status-fd 2 --edit-key "$MASTER_FPR" >"/tmp/.rotate-revoke.$$" 2>&1 <<EOF || true
key $OLD
revkey
y
$REASON_CODE
$REASON_TEXT

y
save
EOF
    val="$(sign_subs | awk -v o="$OLD" '$1==o{print $2}')"
    if [ "$val" != "r" ]; then
      sed -n '1,40p' "/tmp/.rotate-revoke.$$" >&2 || true
      rm -f "/tmp/.rotate-revoke.$$"
      die "revocation of $OLD did not take (validity='$val', wanted 'r')"
    fi
    rm -f "/tmp/.rotate-revoke.$$"
    ok "Revoked $OLD"
  done
fi

# ---- 3. re-export the public key ------------------------------------------
CURRENT_STEP="export-pubkey"
step "Writing ./pubkey.gpg (full public key)…"
gpgm --batch --armor --export "$MASTER_FPR" > pubkey.gpg
grep -q 'PUBLIC KEY BLOCK' pubkey.gpg || die "pubkey.gpg export looks empty"
# confirm the new subkey is present in the exported public key
if ! gpg --show-keys --with-colons pubkey.gpg | awk -F: '$1=="fpr"{print $10}' | grep -qx "$NEW_SUBKEY"; then
  die "exported pubkey.gpg does not contain the new subkey $NEW_SUBKEY"
fi
ok "pubkey.gpg contains the new subkey"

# ---- 4. self-test: sign + verify with the NEW subkey ----------------------
CURRENT_STEP="self-test"
step "Self-test: sign and verify with the new subkey…"
TMP="$(mktemp -d)"; echo "rotation self-test $$" > "$TMP/m"
gpgm --batch --local-user "${NEW_SUBKEY}!" --armor --detach-sign -o "$TMP/m.sig" "$TMP/m" \
  || { rm -rf "$TMP"; die "signing with new subkey failed"; }
used="$(gpg --status-fd 1 --verify "$TMP/m.sig" "$TMP/m" 2>/dev/null | awk '/VALIDSIG/{print $3}')"
rm -rf "$TMP"
[ "$used" = "$NEW_SUBKEY" ] || die "self-test signature used '$used', expected new subkey $NEW_SUBKEY"
ok "Signed & verified with the new subkey"

# ---- 5. update the GitHub credential --------------------------------------
CURRENT_STEP="publish-secret"
if [ "$PUSH" = 1 ]; then
  step "Updating GitHub secret GPG_PRIVATE_KEY on $REPO (subkey streamed, never printed)…"
  gpgm --batch --armor --export-secret-subkeys "${NEW_SUBKEY}!" | gh secret set GPG_PRIVATE_KEY --repo "$REPO"
  printf '%s' "$MASTER_FPR" | gh secret set GPG_KEY_ID --repo "$REPO"   # unchanged, re-set for safety
  ok "GPG_PRIVATE_KEY updated (GPG_KEY_ID still = master fpr)"
else
  step "--no-push selected. Run this to update the CI signing subkey in GitHub, then re-publish:"
  echo
  echo "    gpg --pinentry-mode loopback --export-secret-subkeys '${NEW_SUBKEY}!' | gh secret set GPG_PRIVATE_KEY --repo $REPO"
fi

cat <<NEXT

────────────────────────────────────────────────────────────────────────
${c_green}Rotation complete.${c_off}
  Master (unchanged) : $MASTER_FPR
  New signing subkey : $NEW_SUBKEY
$([ "$KEEP_OLD" = 1 ] || printf '  Revoked old subkey : %s\n' "${OLD_VALID[*]:-none}")

Next:
  1. Publish: gh workflow run publish.yml --repo $REPO
     (CI re-signs InRelease with the new subkey and rewrites pubkey.gpg.)
  2. Clients must refresh the key to keep verifying updates:
       curl -fsSL https://${REPO%%/*}.github.io/${REPO##*/}/pubkey.gpg \\
         | sudo gpg --dearmor -o /usr/share/keyrings/openbao-cs.gpg
     The apt source line is unchanged (master fingerprint is stable).
  3. Re-back-up your master (its subkey list/revocations changed):
       gpg --armor --export-secret-keys $MASTER_FPR > openbao-apt-MASTER.asc
────────────────────────────────────────────────────────────────────────
NEXT
