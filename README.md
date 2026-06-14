# openbao-apt

A **self-hosted, GPG-signed apt repository** for [OpenBao](https://openbao.org), served from
GitHub Pages and kept in sync with upstream [GitHub Releases](https://github.com/openbao/openbao/releases)
by a scheduled GitHub Actions job. It lets Ubuntu/Debian hosts do:

```bash
sudo apt update && sudo apt install openbao
```

and receive updates as new OpenBao versions ship.

> **Unofficial.** There is no official OpenBao apt repo; upstream only offers manual `.deb`
> downloads for Debian/Ubuntu. This repository is maintained by **contain-security** and is
> not affiliated with the OpenBao project. Every `.deb` is verified against OpenBao's own GPG
> signature *before* being re-signed and published here.

Published at: **https://contain-security.github.io/openbao-apt**

## Documentation

- [Quick-Start Guide](docs/quick-start.md) — install on a host, or stand the repo up from scratch
- [Operations Guide](docs/operations.md) — running, monitoring, key rotation, troubleshooting, break-glass
- [Developers Guide](docs/developers.md) — architecture and how everything flows (with diagrams)

## Client setup

```bash
curl -fsSL https://contain-security.github.io/openbao-apt/pubkey.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/openbao-cs.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openbao-cs.gpg] \
https://contain-security.github.io/openbao-apt stable main" \
  | sudo tee /etc/apt/sources.list.d/openbao-cs.list

sudo apt update && sudo apt install openbao   # or: openbao-hsm
```

- **Suite:** `stable` · **Component:** `main` · **Architectures:** `amd64`, `arm64`
- **Packages:** `openbao`, `openbao-hsm`
- The repo always serves the **latest** release. reprepro holds one version per package/arch
  (it auto-replaces older with newer and prunes the stale `.deb` from `pool/`), so
  `apt upgrade` always moves hosts to the newest OpenBao.

## How it works

| Branch | Holds |
| --- | --- |
| `main` | Source: the workflow, scripts, reprepro config template, this README. |
| `gh-pages` | The published apt repo (`pubkey.gpg`, `dists/`, `pool/`, `index.html`) **plus** reprepro's `conf/` and `db/` state. Served by GitHub Pages. |

On a 6-hourly schedule (and on manual dispatch) [`.github/workflows/publish.yml`](.github/workflows/publish.yml):

1. Checks out the current `gh-pages` repo into `public/`.
2. Runs [`scripts/publish.sh`](scripts/publish.sh), which:
   - queries upstream releases, selects the newest eligible versions (`>= 2.5.0`, the
     `openbao_`-prefixed asset era);
   - downloads any `.deb`s not already present;
   - **verifies each `.deb` against its upstream `*.deb.gpgsig`** using OpenBao's release key
     (build aborts on mismatch);
   - ingests them with `reprepro`, re-signing `Release` → `InRelease`/`Release.gpg` with our key.
3. Commits and pushes the updated tree back to `gh-pages`.

`publish.sh` performs **no git operations** — it only builds the `public/` tree, which keeps it
fully testable locally.

## One-time maintainer setup

1. **Create the signing key and push secrets.** Uses an **offline-master** model: the
   master key `[C]` is generated into *your* GPG keyring and never leaves this machine; only
   a signing-only **subkey** `[S]` is exported to GitHub.

   ```bash
   gh auth login
   scripts/setup-signing.sh --repo contain-security/openbao-apt
   # or, to review before touching GitHub:
   scripts/setup-signing.sh --no-push   # prints the exact `gh secret set` commands
   ```

   This sets two repo secrets — `GPG_PRIVATE_KEY` (the **subkey** secret only) and
   `GPG_KEY_ID` (the **master** fingerprint, which `reprepro` signs *with via the subkey*) —
   and writes a local `pubkey.gpg`. Then follow the printed steps: back up the master secret
   offline, and optionally `gpg --passwd` it to add a passphrase (the already-exported CI
   subkey is unaffected).

2. **Trigger the first publish:**

   ```bash
   gh workflow run publish.yml --repo contain-security/openbao-apt
   ```

3. **Enable Pages:** repo *Settings → Pages → Source: Deploy from a branch → `gh-pages` / `/ (root)`*.

## Local testing (no key, no push)

```bash
scripts/test-local.sh
```

Generates a throwaway key, builds `./public`, runs `reprepro check`, serves it over HTTP, and
(if Docker is present) installs `openbao` inside a clean `ubuntu:24.04` container to prove apt
signature verification and package resolution end-to-end.

## Configuration

Both scripts read the same env knobs (defaults shown):

| Var | Default | Meaning |
| --- | --- | --- |
| `KEEP_VERSIONS` | `1` | Most-recent releases to ingest. reprepro keeps one version per package/arch, so the repo always serves the latest. |
| `ARCHES` | `amd64 arm64` | Architectures to publish. |
| `PACKAGES` | `openbao openbao-hsm` | Upstream package basenames to mirror. |
| `MIN_VERSION` | `2.5.0` | Ignore older releases (pre-`openbao_` naming). |
| `VERIFY_UPSTREAM` | `1` | Verify upstream `.deb.gpgsig` before ingest. |
| `OPENBAO_GPG_KEY_URL` | openbao.org key | Upstream release public key used for verification. |

Adding an architecture is a two-line change: extend `Architectures:` in
[`conf/distributions.tmpl`](conf/distributions.tmpl) and `ARCHES` in the workflow env.

## Security notes

- **Signing key (offline master + CI subkey).** The master key `[C]` stays in the
  maintainer's own keyring and is **never** sent to GitHub. Only a passphrase-less signing
  subkey `[S]` is exported to the `GPG_PRIVATE_KEY` Actions secret and imported into an
  ephemeral runner keyring — the master secret is absent in CI (`sec#`). reprepro signs
  `InRelease` with the subkey (`SignWith` is the master fingerprint; gpg auto-selects the
  subkey). Compromise of the runner is contained to the subkey, which the master can revoke.
- **Supply chain.** Re-publishing is gated on verifying OpenBao's upstream signature, closing
  the gap between download and republish. Clients trust **our** signature via the pinned
  `signed-by` keyring — apt never makes a cross-origin fetch because the `.deb`s live in our
  own `pool/`.
- **Key rotation.** Use [`scripts/rotate-signing-key.sh`](scripts/rotate-signing-key.sh) — it
  adds a fresh signing subkey, revokes the old one, re-exports `pubkey.gpg`, runs a
  sign+verify self-test, and updates the `GPG_PRIVATE_KEY` secret, **verifying the
  postcondition of every step** and aborting loudly (naming the step) on any mismatch. It
  prompts for your master passphrase up-front and drives gpg with loopback pinentry, so no
  GPG dialog ever pops up. The **master identity is stable**, so the apt source line is
  unchanged; clients re-fetch `pubkey.gpg` to pick up the new subkey. Then dispatch the
  workflow. For a suspected compromise add `--compromised`; to stage changes without touching
  GitHub add `--no-push`.
