# Rebuild notes (bootstrap)

Draft collected during the 2026-10 IaC audit. It records what a rebuild of node-2 needs that is easy to miss. It is not a
tested one-command rebuild; see `docs/INVENTORY.md` for the gaps that remain.

## AWX job templates on a new server

OpenTofu defines AWX templates in two places in `infra-bootstrap/awx-config`: `main.tf` and `extra_job_templates.tf`.

The AWX on node-2 also holds 10 job templates that were created by hand in the UI and are **not** managed by OpenTofu (the
AWX provider cannot import job templates):

| Template | Playbook |
|---|---|
| `lumiether-engineering-check`, `lumiether-engineering-apply` | `configure_engineering_foundation.yml` |
| `lumiether-memory-check`, `lumiether-memory-apply` | `configure_engineering_memory.yml` |
| `lumiether-plans-apply` | `configure_plan_registry.yml` |
| `lumiether-plum-readonly-apply` | `configure_plum_readonly.yml` |
| `lumiether-workspaces-apply` | `configure_workspace_map.yml` |
| `install-android-sdk` | `install_android_sdk.yml` |
| `install-codebasemem` | `install_codebasemem.yml` |
| `install-flutter` | `install_flutter.yml` |

**A new server must set `extra_recreate_hand_made = true`** (the first line of `locals` in
`awx-config/extra_job_templates.tf`) before running `tofu apply` in `awx-config`. A fresh AWX does not have these templates,
and with the default `false` OpenTofu would skip them, so a rebuild through AWX would silently lack those playbooks.

Keep it `false` on node-2's existing AWX: with `true`, OpenTofu would try to create templates whose names already exist.
(To bring node-2's hand-made templates under OpenTofu, delete them in AWX first, then set `true`.)

Other things to know when recreating AWX objects:

- Playbooks must be merged to the default branch of `lumi-playbooks` and the AWX project synced before `tofu apply`; a
  template cannot be created for a playbook AWX has not synced.
- No template asks for variables on launch. `configure_sudoers.yml` in particular must never get launch-time variables
  (anyone who can launch it could add users with passwordless root).
- Do not `tofu apply` an old copy of `awx-config`: it carries state that refers to a template (id 15) that was repurposed
  in the UI. The current `main.tf` drops it with `removed` blocks.

## Secrets that must be restored before the playbooks can finish

They are not in Git and not created by Ansible. Restore them from the encrypted secrets backup
(`scripts/restore.sh apply <dir> secrets`):

- `~/.cloudflared/<tunnel-id>.json` (tunnel credentials): `configure_cloudflared.yml` stops with a message if it is missing.
- `/etc/lumiether/adapter.env` (bearer key of the WIF adapter, must equal `LUMI_ADAPTER_KEY` in the vibe-cbm Portainer
  stack): `configure_wif_adapter.yml` creates it only when missing and a key is supplied, and never generates one.
- `/etc/lumiether/deploy-keys/engineering` (read key for lumiether-engineering): `configure_engineering_foundation.yml`.
- `~/.ssh` keys, the OpenTofu `.envrc-awx` and `.envrc-portainer` files.

## Order hints

- `configure_spire_agent.yml` before `configure_wif_adapter.yml` (the adapter needs the token file written by `vibe-token`).
- The vibe-cbm compose network (subnet `172.19.0.0/16`) must exist for the bridge adapter to bind `172.19.0.1:8091`; the
  unit keeps retrying until it does.
- Private images come from `ghcr.io/lumiether-research`; the host and Portainer need a read-only registry login first.
