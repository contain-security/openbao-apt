# Quick-Start Guide

Fast paths for the two things people actually do with this repository: **install OpenBao on
a host**, and **stand the apt repo up from scratch**. Deeper material lives in the
[Operations Guide](operations.md) and [Developers Guide](developers.md).

Repository: `contain-security/openbao-apt` → served at
**https://contain-security.github.io/openbao-apt**

---

## A. Install OpenBao on an Ubuntu / Debian host (client)

Copy-paste, as a user with `sudo`:

```bash
# 1. Trust the repo's signing key
curl -fsSL https://contain-security.github.io/openbao-apt/pubkey.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/openbao-cs.gpg

# 2. Add the apt source (architecture is detected automatically)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openbao-cs.gpg] \
https://contain-security.github.io/openbao-apt stable main" \
  | sudo tee /etc/apt/sources.list.d/openbao-cs.list

# 3. Install
sudo apt update && sudo apt install openbao
```

- HSM build instead: `sudo apt install openbao-hsm`.
- Updates arrive with normal `sudo apt update && sudo apt upgrade` — the repo always serves
  the latest release.
- Supported architectures: `amd64`, `arm64`.

To remove the repo later:

```bash
sudo rm /etc/apt/sources.list.d/openbao-cs.list /usr/share/keyrings/openbao-cs.gpg
sudo apt update
```

> **Trust note.** This is an *unofficial* repository. Each `.deb` is verified against
> OpenBao's own GPG signature before being re-signed and published here, but you are
> ultimately trusting the `contain-security` signing key you installed in step 1.

---

## B. Stand the repository up from scratch (maintainer)

Prerequisites: `git`, `gpg` (2.4+), and the GitHub CLI `gh` authenticated as the owner
(`gh auth login`). One-time, end to end:

```bash
# 0. (first time only) create the GitHub repo and push this source
gh repo create contain-security/openbao-apt --public --source=. --remote=origin --push

# 1. Create the signing key + push the CI secret.
#    Master key [C] is generated into YOUR keyring and never leaves this machine;
#    only a signing subkey [S] is sent to GitHub Actions.
scripts/setup-signing.sh --repo contain-security/openbao-apt
#    (use --no-push first if you want to review the `gh secret set` commands)

# 2. Back up your master offline, then optionally protect it with a passphrase
gpg --armor --export-secret-keys <MASTER_FPR> > openbao-apt-MASTER.asc   # move offline
gpg --passwd <MASTER_FPR>                                                # optional

# 3. Run the first publish
gh workflow run publish.yml --repo contain-security/openbao-apt

# 4. Enable GitHub Pages: repo Settings → Pages →
#    "Deploy from a branch" → Branch: gh-pages → / (root)
```

After the workflow's first successful run, the `gh-pages` branch and the Pages site exist,
and any host can follow section A.

The two secrets created in step 1:

| Secret            | Contents                                  |
| ----------------- | ----------------------------------------- |
| `GPG_PRIVATE_KEY` | the **signing subkey** secret (only)      |
| `GPG_KEY_ID`      | the **master** key fingerprint            |

---

## C. Try it locally first (no GitHub, no real key)

```bash
scripts/test-local.sh
```

Generates a throwaway key, builds the repo into `./public`, runs `reprepro check`, serves it
over HTTP, and — if Docker is available — installs `openbao` inside a clean `ubuntu:24.04`
container to prove signature verification and package resolution end to end. Nothing is
pushed and your real keyring is untouched.

---

## Where to go next

- Routine running, monitoring, key rotation, troubleshooting → **[Operations Guide](operations.md)**
- How the pieces fit and data flows → **[Developers Guide](developers.md)**
