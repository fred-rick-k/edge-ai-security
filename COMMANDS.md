# Command Reference

> **Document Purpose:** Reference for the modes, flags, stages, and make targets of the installation scripts, for re-running a single part, recovering from a failure, or starting from scratch.
>
> **Related Documents:**
> - Project overview and quickstart: [`README.md`](README.md)
> - System component topology: [`ARCHITECTURE.md`](ARCHITECTURE.md)
> - TPM enrollment and attestation sequence diagrams: [`TPM_ATTESTATION_ARCH.md`](TPM_ATTESTATION_ARCH.md)
> - Threat analysis and security register: [`THREAT_MODEL.md`](THREAT_MODEL.md)

---

## Installation Script Modes and Flags

`./scripts/install-all.sh` is enough for a normal installation. This document lists the modes and flags of the installation scripts, for re-running a single part, recovering from a failure, or starting from scratch. `install-all.sh`, `bootstrap-mac.sh`, and `bootstrap-jetson.sh` are run from the workstation, from the repository root, and read their settings from `.env`. The `make` targets and `vault/gen-tls.sh` run on the control plane server; `cleanup-jetson.sh` runs on the Jetson.

### `scripts/install-all.sh`

```text
./scripts/install-all.sh [<jetson-ip>|<user>@<jetson-ip>] [--force-tls] [--skip-smoke]
```

| Option | Effect |
|---|---|
| `<jetson-ip>` or `<user>@<jetson-ip>` | Jetson to install on. Default: `JETSON_IP` and `JETSON_USER` from `.env`. |
| `--force-tls` | Passed to `bootstrap-mac.sh`: replaces the Vault TLS certificate. See `--force-tls` below. |
| `--skip-smoke` | Skips the final `make demo-smoke-test`. |

Phases, in order: `mac-base`, `tpm2-gate`, `mac-tpm-roles`, `jetson`, `mac-proofs`, `smoke-test`. A phase that did not start is reported as "not run" in the summary. The script has no reset option; for a from-scratch install see [Starting from scratch](#starting-from-scratch).

### `scripts/bootstrap-mac.sh` (control plane)

```text
./scripts/bootstrap-mac.sh [--only-step <step>[,<step>...]] [--force-tls] [--reset-mac] [--list]
```

| Option | Effect |
|---|---|
| *(none)* | Runs all steps in order. |
| `--only-step <list>` | Runs only the listed steps, always in the canonical order. |
| `--force-tls` | Replaces an existing Vault certificate and key. Every consumer of the old certificate (vault-agent configs, `trusted-edge`, the OpenShell gateway CA bundle) stops working until the new `tls/vault.crt` reaches the Jetson and those stages are re-run. |
| `--reset-mac` | Full wipe of the control plane, then stops (it does not rebuild). Asks you to type `RESET`. Cannot be combined with `--only-step` or `--force-tls`. |
| `--list` | Prints the step names and exits. |

| Step | What it does |
|---|---|
| `sync` | Copies the repository to the control plane server (no `--delete`; never touches `tls/`, `.env`, `.vault-keys.json`, logs). |
| `env` | Copies the workstation `.env` and validates it. |
| `tls` | Creates the Vault TLS key and certificate if missing (`vault/gen-tls.sh`). |
| `cert` | Copies the public `tls/vault.crt` back to the workstation, so the Jetson stages can distribute it. |
| `up` | `make up-mac`: starts Vault and PostgreSQL. |
| `vault` | `make setup-vault`: initializes, unseals, and provisions Vault. |
| `tpm` | `make setup-tpm-auth`: enables `auth/tpm` and enrolls the Jetson TPM (needs the Jetson reachable from the control plane). |
| `roles` | `make setup-roles`: splits the TPM roles and policies. |
| `reader` | `make setup-control-reader`: creates the control-plane-reader AppRole. |
| `resume` | `make install-mac-resume`: installs the login unseal job. |

### `scripts/bootstrap-jetson.sh` (edge device)

```text
./scripts/bootstrap-jetson.sh [<jetson-ip>|<user>@<jetson-ip>] [options]
```

The script copies the repository to the Jetson (`rsync --delete`; among the excluded paths are `tls/`, `models/`, `.setup-state/`, and `.env`), pushes an allow-listed `.env` that contains no camera URL, database password, or Vault licence, prompts once for the Jetson sudo password, and runs `setup-jetson.sh` there. Without a host argument it uses `JETSON_IP` and `JETSON_USER` from `.env`.

| Option | Effect |
|---|---|
| *(none)* | Runs every stage that has no marker yet, in the default order below. |
| `--only-stage <name>` | Runs only that stage (names in the stage table). |
| `--phase <1\|2\|3\|5>` | Runs the pending stages of one phase: 1 = steps 1 to 4, 2 = `webui` (step 5) and `webui-smoke` (step 16), 3 = `openshell` (step 10), `agent-sandbox` (step 12) and `openshell-test` (step 13), 5 = steps 6 to 8. |
| `--reset-stage <name>` | Deletes that stage's marker, then runs the stage. Accepts the same names, or a raw marker name. For a stage without a marker, nothing is deleted. |
| `--reset-all` | Deletes the ingest-key chain (sandbox `camera-agent`, providers and profiles `edge-ingest` and `cosmos-vlm`, the stored ingest-key hash in Vault KV) and all stage markers, then runs the default order. Asks you to type `RESET`. Cannot be combined with `--cleanup`, `--reset-stage`, `--only-stage`, or `--phase`. |
| `--no-run` | Only with `--reset-all`: stops after the reset and does not run the default order. |
| `--cleanup` | Reverts the stages on the Jetson (runs `cleanup-jetson.sh`). See [Cleanup](#cleanup). |
| `--stage <name>`, `--full` | Cleanup options. `--stage` implies `--cleanup`. |

Each option also accepts the `--option=value` form.

**Default order** (16 steps, 14 markers): the stage table below lists the stages in the order in which a default run executes them, numbered 1 to 16. The order follows dependencies. For example `webui` (step 5) runs before `openshell` (step 10), because the OpenShell stage stops if the WebUI service is not active (comment above `run_default_order` in `scripts/setup-jetson.sh`). At the end, `setup-jetson.sh` prints every stage as SKIP, RUN-OK, FAIL, or "not run". A stage that was never reached is not reported as passed.

**Stages.** A stage with a marker is skipped when its marker exists in `~/edge-device-demo/.setup-state/` on the Jetson. A stage without a marker runs every time. Some stages need earlier markers or running services and stop with a message if they are missing; the default order respects this. Pass the **name** from the table, or the marker name, to `--only-stage` and `--reset-stage`; do not pass the step number. The step number only labels the position in the default run order, and the dispatcher reads bare numbers as older aliases (for example `--only-stage 5` runs `vlm-smoke`, `scripts/setup-jetson.sh:425`). The end-of-run summary lists stages with a marker by marker name; the four stages without a marker appear as `1-2 (no marker)` (step 2), `1-4 (no marker)` (step 4), `3-2 (no marker)` (step 13) and `2-2 (no marker)` (step 16). The stage dispatcher also accepts a few diagnostic probe stages whose scripts are not part of this repository; they are not supported.

| Step | Name | Marker | Script | What it does |
|---|---|---|---|---|
| 1 | `prep` | `01_prep` | `01-jetson-prep.sh` | Headless mode, clocks, swap, `tpm2-tools`. |
| 2 | `model` | `03_download_model`, `03_pull_container` (written by the script; the stage runs on every launch and skips what is already present) | `03-download-model.sh` | Downloads the GGUF model and the vision projector; pulls the llama.cpp image. |
| 3 | `vlm` | `08_services` | `04-install-services.sh` | Installs `vlm-server.service` with the zero-swap lock. |
| 4 | `vlm-smoke` | *(none)* | `05-smoke-test-inference.sh` | Inference smoke test. |
| 5 | `webui` | `09_webui` | `09-install-webui.sh` | Installs `live-vlm-webui.service`. |
| 6 | `tpm-agent` | `11_tpm_agent` | `11-tpm-enroll-and-agent.sh --instance edge` | TPM attestation and the edge-role `vault-agent`. |
| 7 | `tpm-gateway-agent` | `11b_tpm_gateway_agent` | `11-tpm-enroll-and-agent.sh --instance gateway` | The gateway-role `vault-agent-gateway`. |
| 8 | `agent-pipeline` | `12_agent_pipeline` | `12-install-agent-pipeline.sh` | Transit datakey, dynamic database credentials, agent dependencies. |
| 9 | `trusted-edge` | `13_trusted_edge` | `13-install-trusted-edge.sh` | Installs `trusted-edge.service`. Do not re-run without a deliberate key rotation: it generates a new ingest key. |
| 10 | `openshell` | `10_openshell` | `06-install-openshell.sh` | Installs the OpenShell gateway. |
| 11 | `gateway-vault-driver` | `13a_gateway_vault_driver` | `15-install-gateway-vault-driver.sh` | Gateway Vault credential driver and the `edge-ingest` and `cosmos-vlm` providers. |
| 12 | `agent-sandbox` | `13b_agent_sandbox` | `16-install-agent-sandbox.sh` | Builds the agent image and creates the persistent `camera-agent` sandbox. |
| 13 | `openshell-test` | *(none)* | `07-test-openshell-policy.sh` | Policy test against the running `camera-agent` sandbox. |
| 14 | `camera-credential` | `14_camera_credential` | `17-camera-credential.sh` | Delivers the camera URL to the WebUI through a systemd credential. |
| 15 | `vault-widgets` | `15_vault_widgets` | `21-vault-widgets.sh` | WebUI Vault widgets. Copies only the control-plane-reader `role_id` and `secret_id` from the control plane server. Run `make setup-control-reader` there first. |
| 16 | `webui-smoke` | *(none)* | `10-smoke-test-webui.sh` | WebUI smoke test, including the swap check. |

One more stage exists outside the default order:

| Step | Name | Marker | Script | What it does |
|---|---|---|---|---|
| not in the default order | `wifi-off` | *(none)* | `19-disable-wifi.sh` | Turns the Wi-Fi radio off and pins the Jetson hostname in `/etc/hosts`. Skipped when `DISABLE_WIFI` in `.env` is `false`. |

The numbers in the script file names (`17-camera-credential.sh`, `21-vault-widgets.sh`) are not step numbers; they are the order in which the files were written and do not match the step column.

Common cases:
```bash
./scripts/bootstrap-jetson.sh --only-stage webui              # re-run one stage (skipped if its marker exists)
./scripts/bootstrap-jetson.sh --reset-stage agent-sandbox     # delete the marker, then re-run the stage
./scripts/bootstrap-jetson.sh --phase 2                       # pending stages of phase 2
```

### Cleanup

`bootstrap-jetson.sh --cleanup` runs `scripts/cleanup-jetson.sh` on the Jetson. It reverts services, containers, and installed files, and it removes stage markers. Options forwarded by `bootstrap-jetson.sh`:

| Option | Effect |
|---|---|
| `--cleanup` | Reverts all stages and removes all markers. It asks for no confirmation other than the sudo password. |
| `--cleanup --stage <name>` | Reverts one stage only. Names: `prep`, `model`, `vlm`, `webui`, `openshell`, `tpm-agent`, `tpm-gateway-agent`, `agent-pipeline`, `trusted-edge`, `gateway-vault-driver`, `agent-sandbox`, `camera-credential` (marker names also work). There is no cleanup for `vault-widgets` or `wifi-off`. |
| `--cleanup --phase <1\|2\|3\|5>` | Reverts the stages of one phase only. The phase numbers are those of `cleanup-jetson.sh`: 1 = `prep`, `model`, `vlm`; 2 = `webui`; 3 = `openshell`, `trusted-edge`, `gateway-vault-driver`, `agent-sandbox`, `camera-credential`; 5 = `tpm-agent`, `tpm-gateway-agent`, `agent-pipeline`. This grouping differs from `--phase` without `--cleanup` (see above). |
| `--cleanup --full` | Also deletes the repository copy on the Jetson. Asks you to type `yes`. |

### Starting from scratch

This destroys all Vault data and all stored events. Run the commands in this order, because the first one needs the old Vault to be running:
```bash
./scripts/bootstrap-jetson.sh <jetson-ip> --reset-all --no-run
./scripts/bootstrap-mac.sh --reset-mac
./scripts/install-all.sh
```
`--reset-mac` runs `docker compose down -v` (removes the Vault and PostgreSQL volumes) and deletes `.vault-keys.json`, `tls/vault.crt`, and `tls/vault.key` on the control plane server. It keeps `.env`, the Vault audit log, `.mac-resume.log`, and the login job.

### Other scripts

| Script | Use |
|---|---|
| `vault/gen-tls.sh [--force]` (`make gen-tls`, `make gen-tls FORCE=1`) | Creates the Vault TLS key and certificate on the control plane server if missing. An existing pair is left alone without `--force`. |
| `scripts/mac-resume.sh` | The login job described in [Automated Unseal After Reboot](README.md#automated-unseal-after-reboot). It can also be run by hand. |

### Make targets

Run these from the repository root on the control plane server. The `jetson-*` targets and `bootstrap-jetson` connect to the Jetson over SSH. For these, `HOST` only supplies the address: any `<user>@` prefix is ignored, and the user is `JETSON_USER` from `.env`. Without `HOST`, the address is `JETSON_IP` from `.env`.

| Target | Effect |
|---|---|
| `make help` | Lists the targets. |
| `make up-mac` / `make down-mac` | Start / stop Vault and PostgreSQL (volumes are kept). |
| `make ps` / `make logs` | Show / tail the containers. |
| `make vault-status` | Vault seal and init status. |
| `make gen-tls` | See above. |
| `make setup-vault` | Initialize, unseal, and provision Vault. Safe to re-run. `DB_ROOT_RESET=1 make setup-vault` re-synchronizes the database superuser connection. |
| `make setup-tpm-auth` | Enable `auth/tpm`, create the TPM group, write the edge role. |
| `make setup-roles` | Split the TPM roles and policies; runs the narrowness proofs. Same as `make setup-gateway-credstore`. |
| `make setup-control-reader` | Create the control-plane-reader AppRole. |
| `make install-mac-resume` / `make uninstall-mac-resume` | Install / remove the login unseal job. |
| `make upgrade-vault` | Pull `hashicorp/vault-enterprise:2.2.0-ent`, restart, and re-unseal. |
| `make bootstrap-jetson [HOST=<ip>]` | Runs `bootstrap-jetson.sh` with no stage option. |
| `make jetson-status [HOST=<ip>]` / `make jetson-logs [HOST=<ip>]` | Service state and memory / tail the service logs on the Jetson over SSH. |
| `make demo-smoke-test` | See [Verification & Smoke Testing](README.md#verification--smoke-testing). |
