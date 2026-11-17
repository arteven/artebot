# nanoco-bot OpenShell port: drift from OpenShell v0.1.8 and from our main

Resolves research ticket #2 on map #1. Static analysis only: nothing was run against a live OpenShell gateway. Claims that need a live v0.1.8 gateway are marked **UNVERIFIED**.

Vocabulary: "credential gateway" is the NanoClaw seam (`docs/gateway-seam.md`). "OpenShell gateway" is OpenShell's control plane. "OpenShell provider" is a stored credential. "Agent provider" is Claude, Codex and so on.

## Answer in brief

- Fork: `nanoco-bot/nanoclaw`, HEAD `9467661` (2026-10-08), based on NanoClaw 2026.10.0-rc.2. It pins OpenShell **v0.1.2** (`versions.json`, about 59 "0.1.2" references in code, tests and docs). Our main is 2026.11.0-beta.4.
- Against v0.1.8: every `openshell` CLI flag and JSON shape the fork uses still exists. The policy YAML, driver-config JSON and bind-mount rules are still valid. The code compiles against the same CLI surface. Breakage is in **setup and runtime assumptions**, not in the driver's call sites.
- Against our contracts: the fork lacks `reconcileNetworkAccess`, concurrent-stop sharing and teardown memory, is not in the shared conformance harness, and has no approval bridge.
- Judgement: **port and update the fork**. Write fresh only the approval bridge. Details at the end.

Sources: fork tree at commit `9467661`; OpenShell source at tag `v0.1.8` (https://github.com/NVIDIA/OpenShell/tree/v0.1.8); release notes v0.1.3 to v0.1.8 (https://github.com/NVIDIA/OpenShell/releases). All fork paths below are relative to the fork root and our paths to this repo.

## Fork inventory

- `src/drivers/openshell/`: 22 files, 3747 lines (`driver.ts`, `realize.ts`, `policy.ts`, `host-mount.ts`, `model-provider.ts`, `image.ts`, `settings.ts`, `config.ts`, `register.ts` and others).
- `setup/openshell/*`: `runtime.ts`, `install-step.ts`, `install.sh`, `step.ts`, `verify.ts`, `image.ts`, `wizard.ts`, `resolve-binary.ts`.
- `.claude/skills/add-openshell/`: `SKILL.md`, `gateway.json` (`{kind:"openshell"}`), `scripts/*`, `payload/src/gateway-providers/openshell.ts`, `payload/container/skills/openshell-gateway/`.
- Also `.claude/skills/add-openshell-console/`, `docs/openshell.md`, `docs/openshell-operations.md`.
- It plugs in through the existing seams: `registerSessionDriver('openshell', ...)` in `src/drivers/openshell/register.ts`, appended to `src/drivers/installed.ts`. It is inert unless selected. Our `installed.ts` is an append-only barrel (comment lines 1-8), so the overlay line `import './openshell/register.js'` is compatible.

## Per-file drift table

Effort: S under half a day, M one to two days, L several days or a design decision.
"v0.1.8" rows are breaks against OpenShell. "ours" rows are breaks against our contracts.

| File | Drift | What breaks | Effort |
|---|---|---|---|
| `versions.json`, 59 "0.1.2" refs in code, tests, docs | v0.1.8 | Pin is stale. Tests hard-code `0.1.2`. Bump to exact v0.1.8 and regenerate fixtures. | S |
| `setup/openshell/runtime.ts` (`NEW_GATEWAY_TOML`) | v0.1.8 | The generated `gateway.toml` has no auth section. Since v0.1.6 (#4821) a gateway refuses to start unless OIDC, mTLS, operator auth or `gateway_jwt` is configured, or `[openshell.gateway.auth] allow_unauthenticated_users = true`. Whether the packaged install supplies mTLS or JWT by default is **UNVERIFIED**. Needs an explicit auth decision for a local single-user gateway. | M |
| `setup/openshell/image.ts` (`supervisorImageRef`) | v0.1.8 | Only checks the supervisor image. v0.1.8 has two images, `sandbox_runtime_image` (`ghcr.io/nvidia/openshell/sandbox:<ver>`) and `supervisor_image` (`.../supervisor:<ver>`). Pre-pull and verify both. Also supervisor and gateway must be upgraded together (#4656, v0.1.6). | S |
| `src/drivers/openshell/policy.ts` (default base RO `/usr /bin /lib /lib64 /etc`) | v0.1.8 | #5278 (v0.1.8): a policy path that traverses a symlink inside a writable workspace fails launch, even under `best_effort`. On merged-usr images `/bin`, `/lib`, `/lib64` are root-level symlinks. Whether this trips depends on the image and is **UNVERIFIED**. v0.1.8 also auto-adds baseline paths when a network rule exists, so the fork's list may be partly redundant. | M |
| `src/drivers/openshell/policy.ts` (`landlock.compatibility`) | v0.1.8 | The Landlock baseline needs ABI 3 (Linux 6.2 or newer) and startup fails when it cannot be enforced. The fork docs claim the sandbox runs without filesystem rules in that case. That claim is stale. Linux-only is already a map constraint, so add a host kernel preflight. | S |
| `src/drivers/openshell/policy.ts` (rest) | none | `version:1`, `filesystem_policy`, `process.run_as_*`, `network_policies{name,endpoints,binaries}` are schema-valid at v0.1.8 (`docs/how-it-works/policies/schema.mdx`). Limits: 256 paths, 4096 bytes, `read_write` cannot contain `/`. | none |
| `src/drivers/openshell/realize.ts:96-113` (`createArgs`) | none | `sandbox create --name --from --policy [--driver-config-json] --label --env --cpu --memory --provider --detach --no-tty --no-auto-providers -o json -- cmd`. Every flag still exists at v0.1.8 (`crates/openshell-cli/src/main.rs` around 1446-1640). New and unused: `--restart-policy` (default `never`, matches the fork's assumption), `--env-from`, `--annotation`, `--approval-mode manual\|auto`, `--template`, `sandbox stop/start/suspend/resume`. | none |
| `src/drivers/openshell/realize.ts` (list, get, delete, exec) | none | `sandbox list --selector --page-size --page-token -o json` returns `{sandboxes,next_page_token}`. `sandbox get -o json` still has id, name, labels, phase, exit_code, `configuration_admission{state,error}` (`run.rs:3015`). `status -o json` keeps gateway, server, status, version, authentication. | none |
| `src/drivers/openshell/host-mount.ts` and `compileDriverConfig` | none | `{docker:{mounts:[{type:'bind',source,target,read_only}]}}` still deserializes (`DockerDriverMountConfig`). Bind mounts still need `allow_driver_config = true`, `enable_bind_mounts = true`, `resource_admission.enabled = false` (`openshell-driver-docker/src/lib.rs:1118-1135,1275`; `resource_admission.rs:108-118`). The fork's error-text regexes match the v0.1.8 messages as read in source; the resource-admission text is **UNVERIFIED** live. Its symlink, protected-root and control-character checks are additive: upstream `validate_absolute_mount_source` (`openshell-core/src/driver_mounts.rs:49`) checks only absoluteness. | none |
| `src/drivers/openshell/image.ts`, `setup/openshell/image.ts` | v0.1.8 and Docker leak | Mounts may not replace or contain the image `WORKDIR` (`driver_mounts.rs:200-213`). Our `container/Dockerfile:147` has `WORKDIR /workspace/group` and the session mount is at `/workspace` (`src/container-runner.ts:1207`). The stock image therefore fails. The fork derives an `:openshell` image with `WORKDIR /sandbox`. Mounts under `/app` are fine. Reserved roots: `/opt/openshell`, `/etc/openshell`, `/etc/openshell-tls`, `/run/openshell`, `/run/openshell-sidecar`, `/run/netns`, `/var/run/netns`. Overlaps with the `container/build.sh` leak in map #1. | M |
| `src/drivers/openshell/model-provider.ts` | none | Ships its own two profiles (`nanoclaw-claude-oauth`, `nanoclaw-claude-api-key`) with explicit `auth_style`. #4886 (v0.1.8: static credentials without placement metadata resolve only in `Authorization`) does **not** break them because placement is explicit. "v0.1.2 ships no provider profiles" is still true: profiles under `providers/*.yaml` are examples only. Profiles and providers are workspace-scoped (default workspace `default`), and the fork imports into the current workspace. Pin `OPENSHELL_WORKSPACE`. | S |
| `src/drivers/openshell/driver.ts` (capabilities, about 183-206) | ours | Declares `admissionEnforced:false`, `networkPolicy:'declarative'`, `unrealized:['pidsLimit','shmSizeMb']`, `imageBuild:false`, `watchMode:'polling'`. All fields exist in our `DriverCapabilities` (`src/drivers/types.ts:264` for `networkPolicy`). No break. | none |
| `src/drivers/openshell/driver.ts` (no `reconcileNetworkAccess`) | ours | Our `SessionDriver` has `reconcileNetworkAccess?(access, handle)` returning `NetworkReconcile = 'kept' \| 'restart'` (`src/drivers/types.ts:258-315`). The core uses it when adopting a session (`src/container-runner.ts` around 641-660, `stopIfOffNetworkPolicy`). The fork predates it. An adopted sandbox keeps whatever policy it was created with after a policy change. Needs an implementation (compare a policy hash label, return `'restart'` on mismatch). | M |
| `src/drivers/openshell/driver.ts` (`stop`, about 569) | ours | No concurrent-stop sharing and no teardown memory, which our `docker-driver.ts` (1026 lines) has. `stopGraceSeconds` (types.ts:154) is not realized: OpenShell uses the gateway's own grace. Declare it unrealized or map it. | M |
| `src/drivers/openshell/driver.ts` (labels) | ours | Our `src/container-runner.ts:1486` sets label `nanoclaw-container-name: containerName`, a long value. The fork's `labelValueLegal` check (63 bytes) can reject it. Our own `labelValueLegal` is at `types.ts:389`. Truncate or hash the value, or drop it where the sandbox name already encodes it. | S |
| `src/drivers/openshell/driver.ts` (`sandboxName`) | none | `ncl-` plus 15 hex chars of a sha256 over install, group and session. `MAX_ROUTABLE_NAME_LEN = 19` still holds at v0.1.8 (`openshell-server/src/grpc/mod.rs:157`). `MAX_PROVIDERS` is 32, so a per-session provider list needs a ceiling check. | none |
| `src/drivers/conformance.test.ts` (ours, line 105 `harnesses = [dockerHarness()]`; fork identical) | ours | OpenShell is not in the shared conformance suite. Only the fork's `policy.test.ts:93` uses the shared `spec-fixture.ts`. Needs an `openshellHarness()` over the fake CLI. Our `fake-cli.ts` added `timeoutMs`, `once` and `beforeRun`. | M |
| `src/gateway-providers/*` and `.claude/skills/add-openshell/payload/src/gateway-providers/openshell.ts` | ours | The fork's payload is contract-compatible with `docs/gateway-seam.md` and `setup/gateways/credential-store.ts` as read. But `approvals.subscribe` is a no-op that waits on the abort signal (our contract: `gateway-provider-registry.ts:147-152`, required for every gateway). **No approval bridge exists.** | L |
| `.claude/skills/add-openshell/scripts/credential-store.ts` | none | Uses `provider create --name --type --credential KEY` (env-lookup form), `provider update --credential KEY --wait`, `provider get`, `provider list -o json`. All valid at v0.1.8. Conforms to `ProviderCredentialStore` (seam version 2). The map constraint "credentials via `openshell provider create` directly" is already how it works. | none |
| Docker leaks (map #1): `container-runner.ts:1620,1666`, `egress-lockdown.ts`, `setup/container.ts`, `container/build.sh`, `container/pull.sh` | ours | Not addressed by the fork except through the derived-image workaround. They need capability gating rather than driver-specific code. The `imageBuild` gate at `container-runner.ts:1610` is already the right shape. | M |
| `src/drivers/openshell/settings.ts`, `config.ts` | none | Env keys `OPENSHELL_BIN`, `NANOCLAW_OPENSHELL_{BASE_RO,BASE_RW,LANDLOCK,POLL_MS,POLICY_FILE}`, `OPENSHELL_GATEWAY`, `OPENSHELL_GATEWAY_ENDPOINT`. Still meaningful. Gateway URL at v0.1.8 is `https://127.0.0.1:17670` run as a systemd user service. | none |
| `docs/openshell*.md`, `add-openshell-console` | v0.1.8 | Stale pins and the stale Landlock claim. The console skill is out of scope for map #1. | S |

## Notable design choices (worth keeping)

1. **Docker compute driver, one sandbox per session, polling watch.** `prepare()` compiles the plan and `start()` creates, because `sandbox create` cannot create without starting. `watchMode:'polling'` is declared honestly (`driver.ts:308`, poll interval `NANOCLAW_OPENSHELL_POLL_MS`).
2. **Capabilities that say what is not realized.** `admissionEnforced:false` with a comment not to flip it until label-based admission is configured. `unrealized:['pidsLimit','shmSizeMb']` is named rather than faked. The same style fits our `types.ts`.
3. **Host-side mount validation stays in code.** Because the OpenShell gateway needs `resource_admission` off for bind mounts, nothing out of process re-checks mounts. `host-mount.ts` therefore does its own symlink-component check, a protected-roots list and a unicode/control-character check. Two snippets are derived from NemoClaw (`host-mount.ts:6,102`).
4. **Declarative egress.** `networkPolicy:'declarative'` with a default-deny `network_policies` document compiled from `NetworkAccessIntent`, plus an optional operator policy file (`NANOCLAW_OPENSHELL_POLICY_FILE`).
5. **Own provider profiles with explicit `auth_style`**, so credential placement does not depend on OpenShell defaults (and survives #4886).
6. **Deterministic short sandbox names** (`ncl-` plus 15 hex) under the 19-byte routable limit, with labels for adoption and orphan listing.
7. **Setup is a wizard plus a deterministic step**, Linux-only for writing `gateway.toml`, with a binary resolver and image prep.
8. **Inert unless selected.** Registration is a barrel line; Docker, OneCLI and Iron Proxy are untouched. This matches map #1's overlay constraint.

## Test coverage

- Driver unit tests: `driver.test.ts` (592 lines), `policy.test.ts`, `host-mount.test.ts`, `group-policy.test.ts`, `policy-file.test.ts`, `model-provider.test.ts`, `register.test.ts`, `selection.test.ts`, `capabilities.test.ts`. All run against a fake CLI, never a live gateway.
- Not covered: the shared driver conformance suite, any live-gateway test, the setup wizard end to end, and the approval path (it does not exist).
- Tests hard-code `0.1.2`, so a pin bump is a test-visible change.
- Live behaviour at v0.1.8 (Landlock on the host kernel, symlink rule, auth defaults) has no test and remains **UNVERIFIED**.

## License and attribution

- Fork license: MIT, "Copyright (c) 2026 Gavriel", the same notice as ours. Importing MIT code requires keeping its copyright notice. Because the notices match, the practical risk is low, but record provenance in the skill's README or commit trailer.
- NemoClaw-derived snippets (Apache-2.0) in `host-mount.ts:6,102`. There is no `NOTICE` file and there are no per-file SPDX headers. Apache-2.0 requires keeping the license text and a notice of changes. Either add a `NOTICE` entry or rewrite those two snippets from the OpenShell docs.
- OpenShell itself is Apache-2.0 (https://github.com/NVIDIA/OpenShell/blob/v0.1.8/LICENSE). We only call its CLI and bundle none of its code, so no obligations arise beyond documentation.

## OpenShell upgrade notes v0.1.3 to v0.1.8 that matter here

- v0.1.3 and v0.1.4: no upgrade section. v0.1.3 adds a restart policy (#2798) and `provider profile` label support, and a tagless `--from` pulls only `:latest` (#4124). Always pass an explicit tag.
- v0.1.5: external compute drivers rename `outer_fence` to `provisioning_evidence`. The gateway rejects the reserved `internal.openshell.ai/` annotation prefix. Not relevant to the Docker driver.
- v0.1.6: gateway auth required (#4821). Supervisor connection direction flipped, so supervisor and runtime binaries upgrade together (#4656). Adds `sandbox suspend/resume`.
- v0.1.7: OCSF 1.8.0 breaking change (log consumers only). Podman `additional_ca_bundle` deprecated. This matters for the Podman step later.
- v0.1.8: #4886 (credential placement), #5278 (symlink rule), #5336 (REST 403 on HTTP upgrade), IPv4-mapped IPv6 evaluated as IPv4. Upgrade the gateway before the supervisor.

## Judgement: port and update, do not write fresh

**Port.** Reasons:

1. The fork's whole call surface (CLI flags, JSON shapes, policy and driver-config shapes, name length limits, mount error texts) was checked against v0.1.8 source and still holds. The six-release gap changed operations (auth, images, Landlock, symlinks), not the interface the driver uses.
2. The seams it plugs into (`registerSessionDriver`, `installed.ts`, `gateway.json`, `ProviderCredentialStore`) are unchanged in our main. Drift against us is additive: one optional method, stop semantics, a label rule, a conformance harness.
3. About 3700 lines of tested driver, policy, mount-validation and setup code would be rewritten for no gain. The mount-validation and policy work is the part most expensive to get right.

**Bounded work list**, in order:
1. Pin bump to exact v0.1.8, fixtures, docs (S).
2. Setup: auth section in `gateway.toml`, two-image pre-pull, kernel (Landlock ABI 3) preflight, workspace pin (M).
3. Policy base paths versus the v0.1.8 symlink rule; verify live (M).
4. Contract catch-up: `reconcileNetworkAccess`, concurrent-stop and teardown memory, label length, `stopGraceSeconds` (M each).
5. Conformance harness for OpenShell (M).
6. Docker-leak capability gating (M), coordinated with the `container/build.sh` and `:openshell` WORKDIR image.
7. NOTICE entry for the Apache-2.0 snippets (S).

**Write fresh only the approval bridge** (L). The fork's `approvals.subscribe` is a no-op. The design of mapping NanoClaw chat cards to OpenShell rule approvals is owned by the separate approvals research ticket; this report does not duplicate it.

**Risks that could flip the judgement**: if live testing shows the packaged v0.1.8 gateway cannot run bind-mounted sandboxes with `resource_admission` off, or the symlink rule makes the base-path model unworkable, the policy and mount layers would need redesign. Both are **UNVERIFIED**; neither is indicated by source reading.

## Open questions

1. What does the packaged v0.1.8 gateway do for auth by default, and is `allow_unauthenticated_users = true` acceptable for a single-user local gateway? (UNVERIFIED)
2. Does the default base RO list trip #5278 on our image? A live `sandbox create` would settle it.
3. Should the derived `:openshell` WORKDIR image become a first-class build target, or should our main Dockerfile change `WORKDIR` for all drivers?
4. The fork's setup writes `gateway.toml` only on Linux, consistent with map #1. Podman will need `additional_ca_bundle` handling (deprecated in v0.1.7).
