# Operations Guide

Day-to-day running and break-glass procedures for `contain-security/openbao-apt`. Assumes
you've read the [Quick-Start](quick-start.md). For *why* things are shaped this way, see the
[Developers Guide](developers.md).

- **Publish site:** https://contain-security.github.io/openbao-apt
- **Source branch:** `main` · **Published branch:** `gh-pages`
- **Automation:** [`.github/workflows/publish.yml`](../.github/workflows/publish.yml)

---

## 1. How the automation runs

The `publish` workflow runs:

- **on a schedule** — `17 */6 * * *` (every 6 hours, offset off the hour), and
- **on demand** — `workflow_dispatch`.

Each run checks out the current `gh-pages`, syncs new upstream releases into it with
`reprepro`, re-signs, and pushes `gh-pages` back. If there's nothing new, it makes no commit.

```bash
# trigger a run now
gh workflow run publish.yml --repo contain-security/openbao-apt

# watch the latest run
gh run watch --repo contain-security/openbao-apt

# list recent runs / view logs
gh run list   --workflow publish.yml --repo contain-security/openbao-apt
gh run view <run-id> --log --repo contain-security/openbao-apt
```

---

## 2. Routine checks

```bash
# What versions are currently published? (reads the live metadata)
curl -fsSL https://contain-security.github.io/openbao-apt/dists/stable/main/binary-amd64/Packages \
  | grep -E '^(Package|Version):'

# Is the signed index healthy?
curl -fsSL https://contain-security.github.io/openbao-apt/dists/stable/InRelease | head -20
```

From a client host, `apt policy openbao` shows the candidate version and the origin.

There is normally **nothing to do** — new OpenBao releases are picked up within ~6 hours. The
sections below are for when you need to intervene.

---

## 3. Configuration knobs

Set as workflow `env:` (or exported when running scripts locally). Defaults shown.

| Variable             | Default                        | Effect |
| -------------------- | ------------------------------ | ------ |
| `KEEP_VERSIONS`      | `1`                            | How many recent releases to ingest. reprepro keeps **one** version per package/arch, so the repo always serves the latest. |
| `ARCHES`             | `amd64 arm64`                  | Architectures to publish. |
| `PACKAGES`           | `openbao openbao-hsm`          | Upstream package basenames to mirror. |
| `MIN_VERSION`        | `2.5.0`                        | Ignore releases below this (pre-`openbao_` naming). |
| `VERIFY_UPSTREAM`    | `1`                            | Verify each `.deb` against its upstream `*.deb.gpgsig` before ingest. |
| `OPENBAO_GPG_KEY_URL`| openbao.org release key        | Upstream public key used for that verification. |

### Add an architecture

Two edits, then publish:

1. Append it to `Architectures:` in
   [`conf/distributions.tmpl`](../conf/distributions.tmpl).
2. Append it to the `ARCHES` value used by the workflow / `publish.sh`.

(reprepro must know the architecture in `conf/distributions` before any `.deb` of that arch
can be ingested.)

---

## 4. Key rotation

Rotate the CI **signing subkey** (the master never changes) with the purpose-built script —
it verifies every step and won't update GitHub until a sign+verify self-test passes:

```bash
# Stage locally and review first (recommended)
scripts/rotate-signing-key.sh --no-push

# Then perform it for real
scripts/rotate-signing-key.sh

# Suspected key exposure → mark the revocation reason as "compromised"
scripts/rotate-signing-key.sh --compromised
```

It prompts for your master passphrase up-front (no surprise GPG dialog), adds a new signing
subkey, revokes the old one, re-exports `pubkey.gpg`, updates the `GPG_PRIVATE_KEY` secret,
and prints next steps. **Requirements:** your master *secret* must be in the keyring; if you
keep it offline, re-import it first:

```bash
gpg --import openbao-apt-MASTER.asc
```

After rotating:

```bash
gh workflow run publish.yml --repo contain-security/openbao-apt   # re-sign + rewrite pubkey.gpg
```

The apt **source line is unchanged** (master fingerprint is stable). Clients must re-run the
key step from the Quick-Start to keep verifying updates — plan an announcement:

```bash
curl -fsSL https://contain-security.github.io/openbao-apt/pubkey.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/openbao-cs.gpg
```

---

## 5. Troubleshooting

### Client: `NO_PUBKEY` / "signatures couldn't be verified"
The host's stored key no longer matches the repo's signing subkey (usually after a rotation).
Re-import the key (the `curl … | gpg --dearmor …` command above), then `sudo apt update`.

### Client: `404` fetching a `.deb`
Pages may be mid-deploy, or the version was pruned. `sudo apt update` and retry. Confirm the
file exists under `…/pool/main/o/openbao/` on the site.

### Workflow: "no eligible releases found"
Upstream API returned nothing ≥ `MIN_VERSION` (rate limit, or upstream outage). Re-run later.
The workflow uses `GITHUB_TOKEN` to raise the API limit.

### Workflow: "UPSTREAM SIGNATURE INVALID … refusing to publish"
`publish.sh` downloaded a `.deb` whose upstream `*.deb.gpgsig` did **not** verify against the
OpenBao release key. This is a safety stop — **do not bypass it.** Investigate upstream; a
transient/corrupt download will clear on the next run. To temporarily disable verification
(not recommended) set `VERIFY_UPSTREAM=0`.

### Workflow: GPG / signing errors
Check the `GPG_PRIVATE_KEY` (signing subkey) and `GPG_KEY_ID` (master fingerprint) secrets are
present and current. After a rotation that didn't push, the secret may be stale — re-run the
rotation, or push the subkey manually as the script prints.

### Pages not updating
Confirm Pages is set to **Deploy from a branch → `gh-pages` / root**, and that the latest
`publish` run pushed a commit (`gh run list`). Pages can lag a minute or two after a push.

---

## 6. Break-glass

### Lost the master key
If the master secret and all backups are gone, you cannot revoke or extend the existing key.
Generate a brand-new key with `scripts/setup-signing.sh`, publish, and have **every client**
re-import the new `pubkey.gpg`. The apt source line stays the same but trust must be
re-established everywhere — treat as a security event and announce it.

### Rebuild the repo from nothing
The published tree on `gh-pages` is disposable. Delete the branch and re-run the workflow; it
recreates `dists/`, `pool/`, `conf/`, `db/`, `pubkey.gpg`, and `index.html` from scratch using
the secrets and upstream releases.

### Pause publishing
Disable the workflow: `gh workflow disable publish.yml --repo contain-security/openbao-apt`
(re-enable with `enable`). Existing clients keep working against the last published state.
