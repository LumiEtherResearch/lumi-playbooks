# node-2 Infrastructure Inventory and IaC Gap Audit

Audit date: 2026-10-26. Host: node-2 (Ubuntu 26.04.1, single ext4 root on `/dev/nvme0n1p2`, 1.8T). Method: read-only. No secret values were read or recorded; secrets are listed by path and purpose.

**Kind** column: `config` = reproducible text, `data` = state that must be backed up, `secret` = credential or key.

**IaC sources** (abbreviations used below):
- **PB** = `~/lumi-playbooks` (GitHub LumiEtherResearch/lumi-playbooks, run via AWX; this repo).
- **ENG** = `~/lumiether-engineering` (GitHub LumiEther-Research/lumiether-engineering; deployed to `/opt/lumiether-engineering`, in sync).
- **BOOT** = `~/infra-bootstrap` (GitHub LumiEtherResearch/lumi-infra-bootstrap): root `main.tf` (docker, k3s, AWX operator, Portainer), `awx-config/` (OpenTofu, AWX objects), `portainer-config/` (OpenTofu, Portainer stacks).

Items marked *(not verified)* were inferred from names or file listings and not opened.

Repo state: PB, BOOT, ENG have 0 unpushed commits. PB has two untracked files (`configure_sudoers.yml`, `configure_vibe_auth.yml`), deliberately left out of this audit's commit.

---

## 1. OS packages and runtimes

| Item | What | IaC file | Kind |
|---|---|---|---|
| docker.io, docker-compose-v2, containerd | Container runtime | BOOT `main.tf` (`install_docker`, `enable_docker`, `docker_group`) | config |
| k3s (`/usr/local/bin/k3s`, kubectl/crictl symlinks) | Kubernetes hosting AWX | BOOT `main.tf` (`install_k3s`, `kubeconfig_setup`) | config |
| tofu | OpenTofu CLI | NOT IN IAC (apt-installed by hand) | config |
| git, curl, unzip, xz-utils, zip, libglu1-mesa | Base tools | BOOT (`install_git`); PB `install_flutter.yml` | config |
| python3, python3-venv, python3-pip | Python | PB `install_vibe.yml` | config |
| openjdk-21-jdk-headless, adb | Android/Quarkus toolchain | PB `install_android_sdk.yml` | config |
| cloudflared (apt package) | Tunnel client | NOT IN IAC | config |
| google-chrome-stable (+ `~/google-chrome-stable_current_amd64.deb`) | Browser | NOT IN IAC | config |
| code (VS Code) version pin | Pinned VS Code | PB `pin_vscode_version.yml` | config |
| ubuntu-desktop-minimal, gdm, snaps (firefox, snap-store, etc.), ibus/language packs, cups, bluetooth, avahi | Desktop stack | NOT IN IAC (installer default; decide whether the rebuild is headless) | config |
| openvpn.service enabled | VPN client *(not verified; no config seen)* | NOT IN IAC | config/secret |
| `/usr/local/bin/uv`, `uvx` | Python tool manager | PB `install_vibe.yml` *(uv install check)* | config |
| `/usr/local/bin/codebase-memory-mcp` (300 MB) | Code index MCP server | PB `install_codebasemem.yml` (installer pulled from upstream `main`, unpinned) | config |
| `/opt/mistral-vibe` (+ `vibe`, `ast-grep` symlinks), `/opt/uv-python` | Vibe CLI venv, Python 3.12 | PB `install_vibe.yml` | config |
| `/opt/flutter`, `/opt/android-sdk` (group `flutter`, setgid) | Flutter and Android SDK | PB `install_flutter.yml`, `install_android_sdk.yml` | config |
| `/opt/google` | Chrome files | NOT IN IAC | config |
| `/usr/local/bin/install.sh` | Leftover installer script | NOT IN IAC | config |

53 manually installed apt packages in total; the playbooks list roughly a dozen of them.

## 2. Users, groups, ACLs, SSH

| Item | What | IaC file | Kind |
|---|---|---|---|
| node-1 (uid 1000) | Admin/automation owner | NOT IN IAC | config |
| abhi, anish, arun (1001, 1002, 1004) | Developers | PB `provision_developer.yml`, `tasks/lumiether_user.yml` | config |
| ahpd-spike-user (1003) | Spike/test account | NOT IN IAC (also `~/ahpd-spike`, `~/ahpd-spike.sh`) | config |
| groups `lumi-dev` (1006), `flutter` (1005) | Dev group and SDK group | PB `provision_developer.yml`, `install_flutter.yml` | config |
| `/srv/lumiether` (root:root 755; no extra ACLs) | Platform root | PB `configure_plan_registry.yml`, `configure_engineering_memory.yml`, `configure_workspace_map.yml` | config |
| `/srv/lumiether/workspaces/<dev>/<repo>` | Developer workspaces (some bind-mounted read-only) | PB `configure_plum_readonly.yml`, `tasks/workspace_branch.yml`, `vars/workspace_map.yml` | data |
| `/srv/lumiether/workspace-map.json` | Workspace map | PB `configure_workspace_map.yml` | config |
| `/srv/lumiether/engineering-memory/`, `/srv/lumiether/plan-registry/` | Memory and plan stores | PB `configure_engineering_memory.yml`, `configure_plan_registry.yml` (contents are data) | data |
| `~/.ssh/authorized_keys` (node-1) | Who can log in | NOT IN IAC | secret-adjacent |
| `~/.ssh/id_ed25519` (+ `.pub`) | node-1 identity | PB `tasks/plum_dev.yml` references the name; key itself NOT IN IAC | secret |
| `~/.ssh/awx_automation` (+ `.pub`) | AWX to node-2 SSH login | BOOT `awx-config` (credential `node2_ssh`); key material NOT IN IAC | secret |
| `~/.ssh/awx_deploy_key` (+ `.pub`) | AWX read access to the playbooks repo | BOOT `awx-config` (credential `lumi_playbooks_deploy_key`); key material NOT IN IAC | secret |
| `/etc/lumiether/deploy-keys/engineering` (+ `.pub`) | Read key for lumiether-engineering | PB `configure_engineering_foundation.yml` (placement); key material NOT IN IAC | secret |
| Per-developer `~/.vibe/.env` (Mistral API key) | Vibe auth | PB `configure_vibe_auth.yml` (**untracked**, not in Git) | secret |
| Per-developer `~/.ssh/id_ed25519` for plum | Plum dev GitHub access | PB `tasks/plum_dev.yml` | secret |

## 3. sudoers

| File | Content (summary) | IaC file | Kind |
|---|---|---|---|
| `/etc/sudoers.d/node-1` | node-1 full NOPASSWD | PB `configure_sudoers.yml` | config |
| `/etc/sudoers.d/awx-automation` | awx-automation full NOPASSWD (stale: the account does not exist) | none; `configure_sudoers.yml` removes it while the user is absent | config |
| `/etc/sudoers.d/lumiether-memory` | `%lumi-dev` may run `lumi-memory-write` | PB `configure_engineering_memory.yml` | config |
| `/etc/sudoers.d/lumiether-plans` | `%lumi-dev` may run `lumi-plan-register` | PB `configure_plan_registry.yml` | config |

Note (verified 2026-10-26): there is no `awx-automation` user or group (`getent`), no login or sudo by that name in `auth.log` or `last`, the AWX credentials are `node-2-ssh` (username `node-1`), `lumi-playbooks-deploy-key`, Demo Credential (admin) and Galaxy, no AWX host, inventory or job template sets `ansible_user`/user variables, and no repo or OpenTofu file mentions the name. The sudoers file is dead config from 2026-09-24. Correction to the first version of this audit: `configure_sudoers.yml` only ever managed `node-1`.

## 4. systemd units, timers, cron

| Unit | What | IaC file | Kind |
|---|---|---|---|
| `cloudflared.service` + `.d/override.conf` | Cloudflare Tunnel | PB `configure_cloudflared.yml` | config |
| `cloudflared-update.service/.timer` | Tunnel auto-update (package default; timer is disabled) | PB `configure_cloudflared.yml` (keeps it disabled) | config |
| `/etc/cloudflared/config.yml` | Tunnel ingress rules | PB `configure_cloudflared.yml` (`~/.cloudflared/config.yml` is a second, unmanaged copy) | config |
| `~/.cloudflared/cert.pem`, `~/.cloudflared/<tunnel-id>.json` | Tunnel account cert and credentials | NOT IN IAC by design; restored from the encrypted secrets backup, play fails clearly if missing | **secret** |
| `spire-agent.service` + `.d/selfheal.conf` | SPIRE agent | PB `install_spire_agent.yml`, `configure_spire_agent.yml`, `docker/spire-agent/start-agent.sh` | config |
| `spire-oidc.service` + `/usr/local/bin/oidc-discovery-provider` | SPIRE OIDC discovery for Mistral WIF | PB `configure_spire_agent.yml` | config |
| `vibe-token.service` + `/usr/local/bin/vibe-token-refresh` | Refresh Mistral token from SPIRE | PB `configure_spire_agent.yml` | config |
| `wif-adapter.service`, `wif-adapter-bridge.service` | Local Mistral WIF adapter (host and Docker bridge) | PB `configure_wif_adapter.yml` (source and pinned requirements in `files/wif-adapter/`) | config |
| `/etc/lumiether/adapter.env` | WIF adapter environment (adapter key) | PB `configure_wif_adapter.yml`, create-only (fails clearly if missing and no key supplied); value never in Git | **secret** |
| `/etc/lumiether/vibe-model.toml` | Vibe model selection | PB `configure_wif_adapter.yml` (placement); consumers `docker/vibe-cbm/lumiether/gen-config.py`, `docker-compose.yml` | config |
| `lumiether-expose-repos.service/.timer` | Exposes repos read-only to plum | PB `configure_plum_readonly.yml`, `docker/vibe-cbm/lumiether/chat/lumiether-expose-repos.sh` | config |
| `k3s.service`, `k3s.service.env` | Kubernetes | BOOT `main.tf` | config |
| user crontab / `/etc/cron.d` | None custom (only anacron, e2scrub) | n/a | n/a |
| `chrony`, `unattended-upgrades`, `sssd`, `ssh`, `kdump-tools` | Stock services | NOT IN IAC | config |

## 5. Network and firewall

| Item | What | IaC file | Kind |
|---|---|---|---|
| ufw | Inactive | n/a | n/a |
| iptables | Docker and kube-router managed chains; FORWARD default DROP; no hand-written rules found | n/a (runtime-generated) | config |
| `/etc/netplan/00-installer-config.yaml`, `01-network-manager-all.yaml`, `90-NM-*.yaml` | Host network config | NOT IN IAC | config |
| Published ports: 4545–4548 (plum), 8081 (spire-server), 8000/9443 (portainer) | Service exposure | PB `docker/plum/docker-compose.yml`; BOOT `portainer-config`, `main.tf` | config |
| Docker networks `plum_default`, `plum-abhi_default`, `plum-anish_default`, `plum-arun_default`, `spire-server_default`, `vibe-cbm_default`, `coding-agent` | Compose-created networks, plus `coding-agent` | Compose files; `coding-agent` NOT IN IAC *(not verified)* | config |

## 6. Docker

### Containers

| Container | Image | IaC file | Kind |
|---|---|---|---|
| plum, plum-abhi, plum-anish, plum-arun | `valentin2177/plum-code-webui:latest` (digest `sha256:2918a816…`, created 2026-09-10, same in all four) | BOOT `portainer-config/plum.tf`, `plum-instances.tf` (Portainer stacks); PB `docker/plum/docker-compose.yml` | config |
| plum-postgres, plum-{abhi,anish,arun}-postgres | `postgres:17-alpine` | same | config |
| vibe-cbm | `vibe-cbm-vibe-cbm:latest` (locally built) | PB `docker/vibe-cbm/Dockerfile`, `docker-compose.yml` | config |
| spire-server | `ghcr.io/spiffe/spire-server:1.9.6` | BOOT `portainer-config` (`portainer_stack.spire_server`, `null_resource.spire_server_config`) | config |
| portainer | `portainer/portainer-ce:2.39.1` (container uses image ID, tag-less) | BOOT `main.tf` (`docker_container.portainer`) | config |

### Images

| Image | Registry copy? | Note |
|---|---|---|
| `vibe-cbm-vibe-cbm:latest` (1.65 GB) | **No** | Built on this host from PB `docker/vibe-cbm`. Build pulls `codebase-memory-mcp` installer from upstream `main` (unpinned) and `uv` installer from astral.sh, so a rebuild may not reproduce this image. |
| `valentin2177/plum-code-webui:latest` | Yes (Docker Hub), mutable `latest` tag | Not pinned by digest. UI branding is applied by `null_resource.lumians_build` (BOOT `portainer-config/lumians/`; also an untracked copy in `~/lumians`). `/srv/lumians/{backend,dist,cli-providers.js}` is the patched output. Whether the running container uses the patched files via bind mount or a layer was not verified. |
| `postgres:17-alpine`, `ubuntu:24.04`, spire-server 1.9.6 (pinned), portainer-ce 2.39.1 (pinned) | Yes | Fine |

### Volumes (all `local`)

| Volume | Kind | IaC file |
|---|---|---|
| `plum_plum-postgres-data`, `plum-abhi_…`, `plum-anish_…`, `plum-arun_…` | data (plum DBs) | Declared in compose; **contents NOT IN IAC, no backup found** |
| `portainer_data` | data (Portainer DB, stacks, credentials) | BOOT `main.tf` declares the volume; contents not backed up |
| `spire-server_spire_server_data` | data (SPIRE datastore, CA keys) | Declared in stack; contents not backed up |
| `vibe-cbm_cbm-data`, `vibe-cbm_vibe-config`, `vibe-cbm_workspaces` | data (code index, Vibe config and sessions, workspace copies) | PB compose; contents not backed up |

### Bind-mounted host data

| Path | Kind | IaC file |
|---|---|---|
| `/srv/plum`, `/srv/plum-abhi`, `/srv/plum-anish`, `/srv/plum-arun` (`config/`, `data/`) | data (plum config including codex plugin caches, plus app data) | PB `configure_plum_isolation.yml`, `tasks/plum_dev.yml`; contents not backed up |
| `/srv/lumians/` | config (patched UI build output) | BOOT `lumians_build`; regenerable *(not verified)* |
| `/opt/lumiether/{lumians-vision.py,merge-config.py}`, `/opt/lumiether-engineering` | config | PB docker/vibe-cbm/lumiether; ENG |

### Build contexts outside this repo

Workspaces under `/srv/lumiether/workspaces/*` contain application Dockerfiles and compose files (caymas-flutter-web, quarkus-auth/mobile/web, Ai-audio-traning, code-server). These belong to the application repos and are out of scope for host rebuild; their images are not present locally.

## 7. AWX, k3s, Portainer

| Item | What | IaC file | Kind |
|---|---|---|---|
| namespace `awx`: `awx-demo` (web, task, postgres-15), operator | AWX instance, 33 days old | BOOT `main.tf` (`install_awx_operator`, `awx_instance`, `awx_admin_secret`) | config |
| AWX postgres PVC (local-path) | AWX DB: job history, credentials (encrypted) | Not backed up | **data/secret** |
| AWX admin secret | Admin password | BOOT `main.tf` (generated at apply time) | secret |
| AWX objects: org lookup, inventory `lumi_infra`, host `node2`, project `lumi_playbooks`, credentials `node2_ssh` and `lumi_playbooks_deploy_key`, 9 job templates | AWX configuration | BOOT `awx-config/main.tf` | config |
| AWX has 9 job templates covering 7 of the 18 playbooks: `docker_status`, `install_spire_agent`, `install_vibe`, `plum_isolation` (check/apply), `lumiether_vibe` (check/apply), `pin_vscode_version`, `provision_developer` | | BOOT `awx-config/main.tf` | config |
| No AWX template for: `configure_engineering_foundation`, `configure_engineering_memory`, `configure_plan_registry`, `configure_workspace_map`, `configure_plum_readonly`, `configure_spire_agent`, `install_flutter`, `install_android_sdk`, `install_codebasemem`, `configure_sudoers`, `configure_vibe_auth` | These run by hand or never in AWX | NOT IN IAC | config |
| `~/infra-bootstrap/awx-config/.envrc-awx` | AWX API login for OpenTofu | NOT IN IAC (file mode 600, correctly untracked) | secret |
| Portainer admin and API token, `.envrc-portainer` | Portainer API login for OpenTofu | NOT IN IAC | secret |
| Portainer stacks: `plum`, `plum_dev[abhi,anish,arun]`, `spire_server` | Container stacks | BOOT `portainer-config` | config |
| `random_password` / `random_id` resources (plum dev DB, JWT, session, login, encryption) | Generated secrets for each plum instance | BOOT `portainer-config` (values live **only in tfstate**) | secret |
| OpenTofu state: `infra-bootstrap/terraform.tfstate`, `awx-config/terraform.tfstate`, `portainer-config/terraform.tfstate` (+ `.backup`) | State, includes the generated secrets above | Gitignored, no remote backend: **exists only on this server** | secret/data |
| `portainer-config/plum-instances.auto.tfvars` | Per-instance variables | **Tracked in Git** (396 bytes; contents not reviewed, check for emails or secrets) | config |

## 8. Vibe, Plum, bridge

| Item | What | IaC file | Kind |
|---|---|---|---|
| `/usr/local/bin/vibe-acp-bridge` (722 B) | Entry point for ACP chat bridge | PB `docker/vibe-cbm/lumiether/chat/vibe-acp-bridge` (repo copy); install path to `/usr/local/bin` not verified | config |
| `/usr/local/bin/vibe-acp-bridge.bak-keyring`, `.bak-pre-readonly` | Old backups | NOT IN IAC (cruft) | config |
| `/usr/local/bin/lumi-preview` | Preview helper | PB `docker/vibe-cbm/lumiether/lumi-preview` | config |
| `/usr/local/bin/lumi-memory-write`, `lumi-plan-register` | Trusted writers | PB `scripts/`, `configure_engineering_memory.yml`, `configure_plan_registry.yml` | config |
| Vibe agent profiles/prompts (`lumiether.toml`, `lumiether-chat.toml`, prompts, `gen-config.py`, `merge-config.py`, `entrypoint.sh`) | Vibe config generator | PB `docker/vibe-cbm/lumiether/`, `configure_vibe_lumiether.yml` | config |
| Agent profiles and prompts per home | | ENG `agent-profiles/`, `prompts/`; PB `configure_engineering_foundation.yml` | config |
| `/opt/lumiether-engineering` | ENG checkout | PB `configure_engineering_foundation.yml` | config |
| Plum isolation / read-only | | PB `configure_plum_isolation.yml`, `configure_plum_readonly.yml` | config |
| Mistral key/WIF | Auth for Vibe | `configure_vibe_auth.yml` (untracked), SPIRE + `wif-adapter` (see §4) | secret |
| `/opt/spire-agent`, `/opt/spire-server`, `/opt/spire-oidc`, `~/spire-extras-1.9.6*` | SPIRE binaries and config; the extras tarball is a manual download | PB `install_spire_agent.yml`, `configure_spire_agent.yml`; tarball NOT IN IAC | config |
| SPIRE trust bundle and agent SVID data under `/opt/spire-agent` | Identity state | regenerated by join-token flow; join tokens NOT IN IAC | data/secret |
| `~/spire-recover.sh` | Manual recovery script | NOT IN IAC | config |

## 9. Loose files on the host that are not in any repo

`~/lumians/`, `~/lumians-review/`, `~/collect/` (copies of live unit files and configs), `~/plum-ui-src(.tgz)`, `~/plum-instances.tf.bak-*`, `~/audit.sh`, `~/iac-gap-audit.sh`, `~/iac-overview.sh`, `~/enable-container-model.sh`, `~/fix-abhi-vibe.py`, `~/spire-recover.sh`, `~/verify-plum-*.sh`, `~/lumiether-expose-repos.sh`, `~/_oneoff-applied-scripts/`, `~/ahpd-spike*`, `~/vibe-hello`, `~/vis`, `~/vis2`, `~/vis3`, `~/wif-test`, `~/playbooks-aside`, `~/audit-*.txt`, `~/ground-truth-caymas.txt`, `~/google-chrome-stable_current_amd64.deb`.

---

# Gap list, ordered by risk

Each gap is a thing a one-command rebuild cannot recreate.

## A. Exists only on this server (loss = unrecoverable)

1. **OpenTofu state, all three directories, no remote backend.** Contains the generated plum passwords/JWT/encryption keys and the Portainer/AWX resource IDs. Without it, `tofu apply` on a new host would try to recreate everything with new secrets, and the old plum DBs would no longer decrypt.
2. **Docker volumes with no backup**: four plum postgres volumes, `portainer_data`, `spire_server_data` (SPIRE CA), `vibe-cbm_*`. No backup job or cron found.
3. **AWX database** (k3s local-path PVC): holds AWX credentials and job history. No backup.
4. **`vibe-cbm-vibe-cbm:latest`**: built locally, not in any registry. A rebuild depends on unpinned downloads (`codebase-memory-mcp` from upstream `main`, `uv` installer), so it may differ from what is running.
5. **Plum app data and config**: `/srv/plum*/{config,data}` (including codex caches). No backup.
6. **Plum image is the mutable `:latest` tag** of a third-party Docker Hub image; the digest running today could disappear. Also unclear whether the lumians branding is a bind mount of `/srv/lumians` or part of the image.
7. **Source of truth for the UI patch exists twice**: BOOT `portainer-config/lumians/` (tracked) and `~/lumians` (untracked); keep one.

## B. Secrets with no recreation path (need a vault or documented manual step)

8. **Cloudflare tunnel**: `~/.cloudflared/cert.pem` and tunnel credentials JSON, plus `config.yml` and the systemd override. None are in Git. Losing them means a new tunnel, new DNS routes, and new hostnames.
9. SSH keys: `~/.ssh/id_ed25519`, `awx_automation`, `awx_deploy_key`, and `/etc/lumiether/deploy-keys/engineering`. The AWX deploy key must be re-registered in GitHub on rebuild; no record of where the public keys are registered.
10. `/etc/lumiether/adapter.env` (WIF adapter key) and per-developer Mistral keys (`configure_vibe_auth.yml`, untracked).
11. `.envrc-awx`, `.envrc-portainer` (OpenTofu API logins), AWX admin secret, Portainer admin.
12. SPIRE join token/bootstrap for the agent after rebuild.
13. `portainer-config/plum-instances.auto.tfvars` is **tracked** in a GitHub repo; review its contents for anything sensitive.

## C. Services running with no IaC definition

14. **cloudflared** service, override, update timer, and config: now `configure_cloudflared.yml` (gap 3, branch `gap3-collect-playbooks`; AWX templates still to be added).
15. **wif-adapter** and **wif-adapter-bridge** units, the adapter program and its Python environment: now `configure_wif_adapter.yml` plus `files/wif-adapter/` (gap 3; AWX templates still to be added). The old `~/collect` files were redacted copies and one of them (`start-agent.txt`) contains a SPIRE join token; they are not the source of truth and are not tracked.
16. **openvpn.service** enabled with no known config *(not verified)*.
17. **`node-1` sudoers** is now `configure_sudoers.yml` (gap 3), which also removes the stale `awx-automation` file while that user does not exist (see the note in section 3). The node-1 and `ahpd-spike-user` accounts still have no definition.
18. **11 of 18 playbooks have no AWX job template**, including every `configure_engineering_*`, `configure_plan_registry`, `configure_workspace_map`, `configure_plum_readonly`, `configure_spire_agent`, `install_flutter`, `install_android_sdk`, `install_codebasemem`. A rebuild via AWX would skip them.
19. `/usr/local/bin/vibe-acp-bridge` install step is not confirmed in a playbook; repo copy and installed copy should be diffed.

## D. Ordering and bootstrap problems for the "one command" goal

20. Chicken-and-egg: AWX runs the playbooks, but AWX itself is created by BOOT (`main.tf`), whose steps are `null_resource` shell provisioners and use `latest`/unpinned installers (k3s, AWX operator versions not pinned *(not verified)*). BOOT has no top-level entry point that also runs `awx-config`, `portainer-config`, and the playbooks in order.
21. No encoded order between layers: docker, k3s, AWX, tofu apply (awx-config), tofu apply (portainer-config), AWX job runs, SPIRE join, cloudflared login.
22. Desktop stack (gdm, snaps, language packs) and Chrome are installed but unmanaged; the rebuild target is not defined as desktop or headless.
23. Netplan files unmanaged; static addressing assumptions for the new host are undocumented.

## E. Drift and clutter

24. Backup files left in `/usr/local/bin` (`vibe-acp-bridge.bak-*`), `~/plum-instances.tf.bak-*`, leftover `install.sh`.
25. Dozens of stale `lumians-*` and `lumiether-*` branches in PB (local; most appear merged or experimental).
26. One-off scripts in `~/` and `~/_oneoff-applied-scripts` whose effects are applied to the host but not captured in playbooks.
27. `ahpd-spike-user` and `~/ahpd-spike*` appear to be abandoned test assets.
28. Floating versions: `postgres:17-alpine`, `ubuntu:24.04` base, `plum-code-webui:latest`; pinned: spire-server 1.9.6, portainer 2.39.1, Vibe 2.25.8, ast-grep 0.45.3.

## Suggested next steps (not performed; awaiting approval)

1. Back up now: tfstate files, all Docker volumes, AWX DB, `/srv/plum*`, `~/.cloudflared`, `/etc/lumiether`, `~/.ssh`, to an off-host encrypted location.
2. Push `vibe-cbm` and the plum image (by digest) to a registry; pin installer versions in the Dockerfile.
3. Commit `~/collect` content as playbooks (cloudflared, wif-adapter units), track `configure_sudoers.yml`/`configure_vibe_auth.yml` (after review), and add AWX templates for the remaining playbooks.
4. Move OpenTofu state to a remote backend, and add a top-level bootstrap script or Makefile that sequences everything.
5. Decide secret handling (e.g. `ansible-vault` or SOPS) for the keys in section B.
