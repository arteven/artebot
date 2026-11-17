# OpenShell v0.1.8 smoke test: bind mounts, the two-DB SQLite mailbox, and the Claude credential

Run on 2026-11-17 in a nested Ubuntu 24.04 guest under QEMU TCG, inside the sbx sandbox VM. The sbx VM itself cannot run OpenShell sandboxes because it has no Landlock (see check 1). Scripts are in [`scripts/`](scripts/).

## Summary

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Landlock-capable host | **FAIL on the sbx VM, PASS in a nested guest** | sbx VM (kernel 7.0.14, `CONFIG_SECURITY_LANDLOCK` unset, no `/dev/kvm`): `landlock_create_ruleset` returns ENOSYS. Nested guest: kernel 6.8.0-149-generic, **Landlock ABI 4**. |
| 2 | v0.1.8 installs; the OpenShell gateway starts with bind mounts enabled | **PASS** | Official `install.sh` at tag v0.1.8 installs `openshell 0.1.8` (CLI and gateway). It runs on the Docker driver with mTLS, and no config file is needed. |
| 3 | rw bind, ro bind, SQLite `journal_mode=DELETE` both ways, heartbeat mtime | **PASS, only with an explicit `filesystem_policy`** | rw and ro are enforced. Both directions: 0 read errors, 0 write errors, 0 out-of-order reads, `integrity_check` ok. The heartbeat mtime is visible on the host. **Without a policy entry, Landlock denies the bind paths.** |
| 4 | NanoClaw agent image with NanoClaw's `/workspace` binds | **FAIL as-is. PASS with a WORKDIR change plus a policy** | `mount target '/workspace' is reserved for the OpenShell workspace`. A derived image with `WORKDIR /home/node` launches. The symlink rule (#5278) did **not** fire. |
| 5 | Claude credential via an OpenShell provider (`x-api-key`) | **PASS** (API key and OAuth bearer) | Claude Code 2.1.321 accepts the `openshell:resolve:env:…` placeholder and completes a turn. Substitution is proven independently with an echo endpoint. |

Not verified:
- Real KVM performance (TCG timings mean nothing).
- The sandbox's own Landlock error on the sbx VM.
- The real `/app/entrypoint.sh` and agent-runner against live session DBs, end to end.
- Credential rotation and stale placeholders in resumed transcripts.
- A real subscription token.

## Environment

- **Outer sbx VM:** kernel 7.0.14, 16 cores, 14 GB RAM, no `/dev/kvm`, no Landlock. v0.1.8 requires ABI ≥ 3 (`REQUIRED_ABI = 3`, `crates/openshell-sandbox/src/sandbox/linux/landlock.rs`). The support matrix says `best_effort` "never disables this baseline".
- **Nested guest:**
  - Ubuntu noble, built with `debootstrap` into a raw ext4 disk.
  - Booted with `qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu max -smp 12 -m 10240` and direct `-kernel`/`-initrd`, driven over SSH on hostfwd port 2222.
  - LSMs `lockdown,capability,landlock,yama,apparmor`, Landlock ABI 4, Docker 29.10.0. The Docker driver needs Docker ≥ 28.
- **OpenShell:** `openshell 0.1.8` installed from the `.deb`, with the OpenShell gateway as a systemd user unit. `openshell status` shows `Version: 0.1.8` and `Authentication: Authenticated (mTLS transport)`.
- **Agent image:** `nanoclaw-agent-v2-24afc5fb:latest`, 3.05 GB, Debian 12, user `node` (uid 1000), `WORKDIR /workspace/group`. It contains claude-code 2.1.321, bun 1.4.4 and node 22.23.5.

## OpenShell gateway config used (verbatim)

The proxy lines and `proxy_ca_bundle` are only there because sbx forces egress through a TLS-intercepting proxy.

```toml
[openshell]
version = 2

[openshell.gateway]
compute_driver = "docker"

[openshell.drivers.docker]
# --- the ticket's three knobs ---
allow_driver_config = true
enable_bind_mounts = true
# --- sbx-environment only: the supervisor must egress via the outer TLS-intercepting proxy ---
https_proxy = "http://gateway.docker.internal:3128"
no_proxy = "localhost,127.0.0.1,::1,host.openshell.internal"
proxy_connect_by_hostname = true
proxy_ca_bundle = "/home/smoke/.config/openshell/sbx-proxy-ca.pem"

[openshell.drivers.docker.resource_admission]
enabled = false
```

**The third knob is required.** With the `resource_admission` section removed, a raw bind is refused:

```
Error: code: 'The system is not in a state required for the operation's execution',
message: "host bind or image mount cannot be attached while resource admission is enabled: no trusted label resolver"
```

With `enabled = false`, the gateway logs `WARN External resource label admission is DISABLED driver=docker`. **The relaxation applies to the whole OpenShell gateway, not to individual mounts.**

**Default auth.** With no config file at all, the packaged gateway:
- starts and auto-detects the Docker driver;
- binds 127.0.0.1:17670;
- generates a local PKI;
- enables mTLS plus gateway-minted sandbox JWTs.

It needs no auth section and does not refuse to start, so the v0.1.6 #4821 concern does not apply to the package.

## Check 3: bind mounts and the SQLite mailbox

```
openshell sandbox create --name t2 --from smoke-base:1 --policy policy-mounts.yaml \
 --driver-config-json '{"docker":{"mounts":[{"type":"bind","source":"/home/smoke/nc/rw","target":"/mnt/rw","read_only":false},{"type":"bind","source":"/home/smoke/nc/ro","target":"/mnt/ro","read_only":true}]}}' --no-keep --no-tty -- <cmd>
```

`smoke-base:1` is python:3.12-slim plus a non-root `sandbox` user (uid 1000). The default image, `nvcr.io/nvidia/base/ubuntu:24.04`, returns 403 through the sbx proxy, so `--from` is mandatory here.

**Without a policy entry**, the binds mount but are unreadable, and nothing reports an error at create time:

```
ls /mnt/rw  -> Permission denied     (Landlock)
cat /mnt/ro/ro.txt -> Permission denied
echo x > /mnt/ro/z -> Read-only file system   (EROFS from the mount flag)
```

**With this policy:**

```yaml
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /etc, /proc, /dev/urandom, /mnt/ro]
  read_write: [/tmp, /dev/null, /mnt/rw]
```

```
cat /mnt/ro/ro.txt -> hello-ro ; write to /mnt/rw -> OK ; write to /mnt/ro -> Read-only file system
```

When `filesystem_policy` is present, `include_workdir` defaults to false and unlisted paths are inaccessible.

**SQLite, both directions.** The host writes `inbound.db` and reads `outbound.db`; the sandbox does the reverse. Settings: `journal_mode=DELETE`, one writer per file, and a fresh read-only connection per poll (`mode=ro`, `busy_timeout=5000`, `mmap_size=0`), as `readInbound` does in `container/agent-runner/src/mailbox/sqlite/connection.ts`. The sandbox touches `/mnt/rw/.heartbeat` and the host watches its mtime.

Run t3 (300 rows each way, 50 ms step):

```
SANDBOX: reads 336, read_errors {}, max_seen 600, writes 300, write_errors 0, mono_viol 0
HOST:    reads 336, read_errors {}, max_seen 599, writes 300, write_errors 0, mono_viol 0, hb_mtime_changes 332, hb_age 0.09s, integrity_check ok/ok
```

Run t4 (2 ms step; TCG limits it to about 780 iterations per side):

```
SANDBOX: reads 780, errors {}, writes 780, mono_viol 0
HOST:    reads 777, errors {}, writes 777, hb_mtime_changes 770, integrity ok/ok
```

There was no `SQLITE_READONLY_ROLLBACK` or `SQLITE_CORRUPT`, no stale or out-of-order read, and the final counts match. Caveat: this was a same-kernel local ext4 bind mount.

## Check 4: NanoClaw image and mount layout

The mounts mirror `src/container-runner.ts` (`scripts/nc-mounts.json`):
- session dir rw at `/workspace`
- `/workspace/agent` rw
- `/home/node/.claude` rw
- `/app/src` ro

**As-is image:**

```
Error: sandbox entered error phase while provisioning: ContainerCreateFailed:
  mount target '/workspace' is reserved for the OpenShell workspace
```

The image's `WORKDIR /workspace/group` becomes the OpenShell workspace root. A mount target may not equal or contain it (`validate_workspace_mount_target`, `crates/openshell-core/src/driver_mounts.rs`). Mounts below it are fine.

**Minimal fix tested.** Only the WORKDIR changes, in a derived image:

```dockerfile
FROM nanoclaw-agent-v2-24afc5fb:latest
WORKDIR /home/node
```

With no policy it launches (uid 1000 `node`, cwd `/home/node`), but `/app`, `/workspace` and `claude` all give `Permission denied`. With this policy it works:

```yaml
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /bin, /sbin, /etc, /proc, /dev/urandom, /app, /pnpm, /var/log]
  read_write: [/tmp, /dev/null, /workspace, /workspace/agent, /home/node/.claude]
```

```
ls /app -> bun.lock entrypoint.sh node_modules package.json src
claude --version -> 2.1.321 (Claude Code) ; bun --version -> 1.4.4
touch /workspace/agent/x -> OK ; touch /app/src/x -> Read-only file system
```

The merged-usr symlinks (`/bin`, `/lib`) and the `/pnpm` shim did **not** trigger the symlink-in-writable-path rule (#5278), because `/` and `/pnpm` are not writable by `node`.

## Check 5: Claude credential

Two profiles were imported with `openshell provider profile import -f`, and providers were created with `--type <profile> --credential KEY=<dummy>`.

| Profile | Env var | Auth style | Header |
|---|---|---|---|
| `nanoclaw-claude-api-key` | `ANTHROPIC_API_KEY` | `header` | `x-api-key` |
| `nanoclaw-claude-oauth` | `CLAUDE_CODE_OAUTH_TOKEN` | `bearer` | `authorization` |

Both profiles use:
- endpoint `api.anthropic.com:443`, `protocol: rest`, `access: full`, `enforcement: enforce`;
- binaries `/pnpm/global/*/.pnpm/*/node_modules/@anthropic-ai/claude-code/bin/claude.exe`, `/usr/local/bin/node`, `/usr/local/bin/bun`.

**Real Claude binary:** `/pnpm/global/5/.pnpm/@anthropic-ai+claude-code@2.1.321/node_modules/@anthropic-ai/claude-code/bin/claude.exe`. `/pnpm/claude` is a `sh` shim that execs it.

**Substitution proof.** A plain-HTTP echo server ran on the guest at `host.openshell.internal:9999`, which bypasses the outer proxy. Inside the sandbox, `ECHO_KEY` held the 52-character `openshell:resolve:env:...` placeholder. The server received the 30-character dummy secret in `x-api-key`, with `is_placeholder: false`. It logged only the length, a prefix and a hash.

**Claude CLI with the placeholder** (`ANTHROPIC_API_KEY` = `openshell:resolve:env:v1...`):

```
claude -p 'reply with OK' --output-format json --max-turns 1 -> stop_reason end_turn, terminal_reason completed
NET:OPEN ALLOWED .../claude-code/bin/claude.exe(0) -> api.anthropic.com:443 [policy:_provider_pk engine:opa]
HTTP:POST ALLOWED POST https://api.anthropic.com/v1/messages [policy:_provider_pk engine:l7]
NET:OPEN DENIED .../claude.exe -> http-intake.logs.us5.datadoghq.com:443 [transparent_tcp_policy_denied]
```

The OAuth profile behaved the same.

- Claude Code 2.1.321 does no format validation on the placeholder, for either env var.
- The `claude.exe` glob matched, and egress was attributed to `claude.exe`, not to `node` or `bun`.
- The CLI also calls settings, bootstrap, policy_limits, metrics, event_logging and mcp-registry paths on `api.anthropic.com`, all under the same rule. Datadog telemetry is denied, and that does not break the turn.
- **Caveat:** in sbx, the outer proxy injects real Anthropic credentials, so the successful real call does not by itself prove substitution. The echo test above is what proves it.
- Interception is transparent: policy DNS maps `api.anthropic.com` to a synthetic 198.18.x.x address, and no `HTTPS_PROXY` is set in the workload. Only `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` are set.

## Implications for NanoClaw

1. **Bind mounts need three OpenShell gateway settings**: `allow_driver_config`, `enable_bind_mounts` and `resource_admission.enabled = false`. The last one turns off label admission for *every* external resource on that OpenShell gateway.
2. **Every mount target needs a matching `filesystem_policy` entry.** An unlisted bind mounts silently and is then unreadable. The driver must generate the policy from the same mount list, and must also list image code paths (`/app`, `/pnpm`).
3. **The unmodified agent image cannot launch.** `WORKDIR /workspace/group` collides with the `/workspace` session mount, so OpenShell needs a different WORKDIR, either in a derived image or in the shared Dockerfile.
4. **Image rules the driver must respect:**
   - Non-root user with an exact uid; uid or gid 0 is rejected.
   - WORKDIR must exist and contain no symlink components.
   - Image VOLUMEs and mounts must not cover the workdir, its parents, or `/.openshell`.
   - Targets under `/opt/openshell`, `/etc/openshell` and `/run/openshell` are rejected.
5. **OpenShell gateway auth needs no config.** It defaults to mTLS plus JWT.
6. **NanoClaw contributes no credential env vars.** OpenShell injects the placeholder itself. The profile's `binaries` must name `claude.exe`; `node` and `bun` look unnecessary.
7. **Setup preflight** should check:
   - Landlock ABI ≥ 3 (sbx VMs fail this with ENOSYS);
   - Docker ≥ 28;
   - the OpenShell version;
   - that the default `nvcr.io` image is not relied on, by always passing `--from`.
8. **Supervisor egress behind a proxy.** The Docker driver takes operator-owned `https_proxy`, `no_proxy`, `proxy_connect_by_hostname` and `proxy_ca_bundle`.
9. **Notes for repeating this in sbx:**
   - Blocked: `deb.debian.org:80`, `security.debian.org`, `snapshot.debian.org`, `nvcr.io`, `cloud-images.ubuntu.com`.
   - Reachable: `deb.debian.org:443`, `archive.ubuntu.com`, `download.docker.com`, `ghcr.io`, Docker Hub, GitHub releases, npm, `bun.sh`.
   - `container/build.sh` does not work unmodified in sbx, because build containers get no proxy env. `scripts/build-agent-image.sh` patches a copy of the Dockerfile.

## Teardown

- Sandboxes, providers and profiles deleted; the OpenShell gateway stopped; the guest powered off.
- Guest disk, kernel, initrd and SSH keys deleted, along with the temporary Docker config and the build cache.
- Only `nanoclaw-agent-v2-24afc5fb:latest` remains in the sbx VM's Docker.
