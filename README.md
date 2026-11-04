# mikrotik-mgmt-bootstrap

Public bootstrap installer for the **private** application repository
[`it-avp-bali/mikrotik-mgmt`](https://github.com/it-avp-bali/mikrotik-mgmt).

A fresh Linux server cannot clone the private app repository until it has a
credential. This repository contains only the small deploy script, so the server
can download it over HTTPS, generate a **read-only SSH deploy key**, and then
clone the private repository. No GitHub token is stored on the server.

```
Server  --curl-->  this public repo (script only)
   |
   |  generate deploy key, wait for GitHub
   v
GitHub  --clone (read-only deploy key)-->  private app repo
   |
   v
scripts/setup-linux.sh  (Docker, .env, TLS, build; then the web wizard)
```

## What the script does

1. Installs `git` and `openssh-client` when missing.
2. Creates `~/.ssh/artotel_deploy` (Ed25519, no passphrase).
3. Prints the public key and waits until you add it to GitHub.
4. Pins `github.com` host keys and adds the `github-artotel` SSH alias.
5. Verifies the key with `ssh -T git@github-artotel`.
6. Clones `main` into `/opt/artotel-mikrotik-mgmt` (root) or
   `~/artotel-mikrotik-mgmt` (non-root).
7. Runs `scripts/setup-linux.sh` unless `--clone-only` is passed.

## Requirements

- Ubuntu 22.04+ / Debian 12+ (root or a user with `sudo`).
- Outbound HTTPS and SSH (port 22) to GitHub.
- Access to **Settings → Deploy keys** of the private app repository.
- `curl`, `tar`, and `sha256sum` (standard on both distributions).

## Quick start

```bash
curl -fsSL -o /tmp/deploy-server.sh \
  https://raw.githubusercontent.com/it-avp-bali/mikrotik-mgmt-bootstrap/main/deploy-server.sh

curl -fsSL -o /tmp/deploy-server.sh.sha256 \
  https://raw.githubusercontent.com/it-avp-bali/mikrotik-mgmt-bootstrap/main/deploy-server.sh.sha256

cd /tmp && sha256sum -c deploy-server.sh.sha256

sudo bash /tmp/deploy-server.sh
```

Do **not** use `curl ... | sudo bash`: download the file, verify the checksum,
then run it.

### Pinned version (recommended)

Pin the commit so a future push cannot change what the server executes:

```bash
BOOTSTRAP_SHA=<40-character-commit-sha>
BASE="https://raw.githubusercontent.com/it-avp-bali/mikrotik-mgmt-bootstrap/${BOOTSTRAP_SHA}"

curl -fsSL -o /tmp/deploy-server.sh "${BASE}/deploy-server.sh"
curl -fsSL -o /tmp/deploy-server.sh.sha256 "${BASE}/deploy-server.sh.sha256"
cd /tmp && sha256sum -c deploy-server.sh.sha256

sudo bash /tmp/deploy-server.sh
```

Get the current SHA with:

```bash
git ls-remote https://github.com/it-avp-bali/mikrotik-mgmt-bootstrap.git refs/heads/main
```

## Add the deploy key

When the script pauses, copy the printed `ssh-ed25519 ...` line and add it at:

**Private app repo → Settings → Deploy keys → Add deploy key**

- Title: `artotel-server` (or the server hostname)
- Key: paste the public key
- **Allow write access: OFF**
- Click **Add key**

Return to the server and press **Enter**.

## After installation

The script prints the application URL. Open it:

```
https://<server-ip>
```

The certificate is self-signed until you install a trusted one.

No account is created by default. The first page is the one-time wizard:
company name, company logo (PNG/JPEG/WebP, max 512 KB), and the first super
admin. The wizard disappears once an account exists and cannot be replayed.
For a headless server, pass `--create-admin` to create the first admin from
the CLI instead.

## Subsequent deployments

The script is now part of the cloned app repository:

```bash
ssh admin@<server>
sudo bash /opt/artotel-mikrotik-mgmt/scripts/deploy-server.sh --update
```

`--update` refuses a dirty working tree, fast-forwards `main`, rebuilds the
Compose stack, and waits for the backend healthcheck.

## Options

| Option | Purpose |
| --- | --- |
| `--repo-dir=DIR` | Clone/deploy directory |
| `--repo-url=URL` | Override the private remote |
| `--branch=NAME` | Branch to deploy (default `main`) |
| `--key=PATH` | Deploy key path (default `~/.ssh/artotel_deploy`) |
| `--ssh-alias=NAME` | SSH config alias (default `github-artotel`) |
| `--update` | Require an existing clone; pull and rebuild |
| `--clone-only` | Clone only; skip setup/rebuild |
| `--print-key` | Print the public key and exit |
| `--keep-remote` | Do not rewrite an existing `origin` URL |
| `--yes` | Skip the deploy-key confirmation prompt |
| `--admin-username=`, `--admin-password=` | Forwarded to `setup-linux.sh`; implies `--create-admin` |
| `--create-admin` | Create the first admin from the CLI instead of the web wizard |
| `--skip-docker-install`, `--force-env` | Forwarded to `setup-linux.sh` |

Full deployment documentation lives in the private repository at
`docs/DEPLOYMENT_LINUX.md`.

## Security model

- This repository is public and contains **no secrets**, only the installer.
- The private key is generated on the server and never leaves it (mode `600`).
- The deploy key is **read-only** and scoped to the single app repository.
- The script downloads over HTTPS and is verified with SHA-256 before execution.
- Host keys are pinned with `ssh-keyscan`; verify the fingerprint against
  [GitHub's published fingerprints](https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
- Enable 2FA on the GitHub account that owns this repository: anyone who can push
  here can run code as root on servers that execute the script.
- Rotate by deleting the deploy key in GitHub, removing
  `~/.ssh/artotel_deploy*` on the server, and rerunning the script.

## Keeping this repository in sync

`deploy-server.sh` is a copy of `scripts/deploy-server.sh` from the private app
repository. After changing the app script:

```bash
cp scripts/deploy-server.sh ../mikrotik-mgmt-bootstrap/
cd ../mikrotik-mgmt-bootstrap
sha256sum deploy-server.sh > deploy-server.sh.sha256
git add deploy-server.sh deploy-server.sh.sha256
git commit -m "sync deploy script from app repo"
git push
```

Always update the checksum in the same commit.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `sha256sum: no such file` | Download both files into the same directory |
| `checksum mismatch` | Re-download; do not edit the script |
| `Permission denied (publickey)` | Deploy key not added, or added to a different repository |
| `Could not reach github.com` | DNS/firewall blocks port 22 or HTTPS |
| `Docker daemon is not reachable` | Run with `sudo`; Docker install may have failed |
| Nginx exits immediately | `certs/server.key` missing or unreadable by GID 101 |

## License

Internal deployment tooling for ARTOTEL Villa Pererenan. No license is granted
for reuse.
