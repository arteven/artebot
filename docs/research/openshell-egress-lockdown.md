# Does egress lockdown still have a job under OpenShell?

Research for GitHub issue #5 (arteven/artebot). Planning input only; no code was changed.

Vocabulary follows `CONTEXT.md` (an untracked file in the main checkout, `/home/arek/Projects/artebot/CONTEXT.md`; it is not in the worktree): **credential gateway** is NanoClaw's seam, **OpenShell gateway** is NVIDIA's control-plane service, **session driver** is `src/drivers/`.

Sources, all read locally:

- OpenShell: `https://github.com/NVIDIA/OpenShell` at tag `v0.1.8`, commit `f3d976590d3eb1379690a2abaf0f0e26c21d487d`. Cited as `OS@v0.1.8:<path>:<line>`. Also tag `v0.1.2` as `OS@v0.1.2:`, because the reference design targets it.
- Reference design: `https://github.com/nanoco-bot/nanoclaw` at `main`, commit `9467661b1a0d478496433b30083baadc2f0eb7d2`. Cited as `REF:<path>:<line>`.
- This repo: cited as `path:line`.

## Answer

- **The three claims hold at v0.1.8, with one qualification.**
  - The workload container is created with `network_mode: "none"` (`OS@v0.1.8:crates/openshell-driver-docker/src/lib.rs:6322`). The config doc says "Workloads always use network=none" (`lib.rs:204`).
  - TCP and DNS are intercepted by a seccomp-notification broker in the workload and relayed to a separate **supervisor** companion container. That container opens the real upstream connections (`crates/openshell-driver-docker/README.md`, "Runtime Model"; `docs/about/architecture.mdx`, "How a network request travels").
  - Policy is default-deny: with no `network_policies`, "all outbound network access is denied" (`docs/how-it-works/policies/default-policy.mdx`, "Default Network Access").
  - The qualification is that the supervisor runs on **host networking by default** (`supervisor_network_mode` defaults to `Host`, `lib.rs:168-175`; host config at `lib.rs:5221-5260`). Only the workload is fenced by `network=none`. Mediation covers "supported" TCP and DNS operations; other traffic has no route because of the fence. I did not verify non-DNS UDP in detail.
  - `v0.1.2` already had the workload `network_mode=none` (`OS@v0.1.2:crates/openshell-driver-docker/src/lib.rs:5797`). `v0.1.8` adds the `bridge` supervisor mode and `host_gateway_ip`.
- **Guarantees OpenShell already provides.**
  - No direct route out of the workload. Ignoring `HTTPS_PROXY` does not bypass mediation (`docs/security/best-practices.mdx`, "Network Namespace Isolation").
  - The fence is re-checked by OpenShell itself on create (`lib.rs:1817`), on reconcile of a running container (`lib.rs:1519`, failing with `OuterFenceViolation`) and on start (`lib.rs:2516`).
  - Sessions cannot reach each other or the host's network namespace by construction: the workload has no network device, and the supervisor only dials what policy allows.
  - Egress is a default-deny allowlist keyed on host, port and calling binary.
  - DNS is mediated: names no rule covers are refused (`crates/openshell-supervisor-network/src/policy_dns/mod.rs:989`, `policy_dns_ineligible`).
  - This is stricter than NanoClaw's default, because `NANOCLAW_EGRESS_LOCKDOWN` defaults to off (`docs/SECURITY.md:219-221`).
- **What is lost or weakened.**
  - The guarantee is no longer "reach the credential gateway and nothing else". It becomes "reach whatever the current effective policy allows".
  - The effective policy is the base policy plus provider-contributed rules (`docs/how-it-works/policies/overview.mdx`, "Base and Effective Policies"). Attaching an OpenShell provider widens egress beyond what NanoClaw composed.
  - A gateway-wide **global policy** replaces every sandbox's own policy and blocks sandbox policy changes (same page, "Global Policy"). NanoClaw's per-session compiled policy is then ignored.
  - Policy is mutable at runtime. Network rules hot-reload (`manage-policies.mdx`). The operator-approval flow and the policy advisor (opt-in) can add rules. OpenShell also drafts proposals from blocked connections in every sandbox, and automatic approval is opt-in (`advisor.mdx`).
  - Who can edit policy: workspace admins and platform admins, and "local gateways without OIDC role configuration treat authenticated users as Platform Admins" (`docs/how-it-works/workspaces.mdx`, role table). The agent cannot: the workload never receives the sandbox JWT or gateway client credentials (driver README, "Gateway session and TLS"). Docker lockdown, by contrast, is structural at spawn.
  - DNS exfiltration: "A wildcard authorizes DNS queries for every matching name, which can expose a DNS-label exfiltration channel" (`network-rules.mdx`, "Allow Native TCP"). NanoClaw's current lockdown has no DNS handling at all (`src/egress-lockdown.ts`), so I make no claim about Docker-side DNS on `--internal` networks.
  - Reaching the host is possible only through an explicit policy rule for `host.openshell.internal` (`docs/how-it-works/policies/schema.mdx`: network policy never authorizes loopback, but "a rule for `host.openshell.internal` can still reach services on the gateway host").
  - Auxiliary containers are lost: the Docker compute driver makes exactly two containers per sandbox (workload and supervisor). `SandboxSpec` has no sidecar field (`OS@v0.1.8:proto/openshell.proto:1079-1113`).
  - Some settings OpenShell needs for NanoClaw's mounts are gateway-wide (bind mounts, `allow_driver_config`, admission); see the reference design.
- **What an OpenShell session driver must report or do.**
  - `capabilities()`: `networkPolicy: 'declarative'`, `auxiliaryContainers: false`, `sharedNetworkNamespace: false`, `isolationTiers: ['container']`, `admissionEnforced: false` while resource admission is off, `imageBuild: false`, and `unrealized` listing `pidsLimit` and `shmSizeMb`. The reference design reports exactly this (`REF:src/drivers/openshell/driver.ts:183-209`).
  - `prepare()` must refuse specs with auxiliary containers and `session-container` network targets rather than ignore them. That matches `docker-driver.ts` and the conformance rule at `src/drivers/conformance.test.ts:313-326`.
  - `spec.network: 'shared-private'` must be realized as a compiled policy whose only network rules are for the gateway endpoint. A realization that adds operator egress rules or attaches providers is honest only if `capabilities().networkPolicy === 'declarative'` and the contract says what that means.
  - `'none'` must compile to no rules and attach no OpenShell providers. Nothing in-tree produces `'none'` (`src/container-runner.ts:1490` hard-codes `'shared-private'`) and no driver reads the field.
  - `NetworkAccessIntent` cannot express what an OpenShell rule needs. It has only an `endpoint` string, while a rule needs **ports** and **binaries** (`best-practices.mdx`, "Binary Identity Binding"). Both come from operator config in the reference design (`REF:src/drivers/openshell/policy.ts:60-66`, `:228-240`).
  - `reconcileNetworkAccess` is optional (`src/drivers/types.ts:315`). Omitting it means an adopted sandbox is silently kept (`src/container-runner.ts:643-670`). OpenShell converges by hot-reloading network policy, not by restarting. An honest implementation compares the live effective policy with the one a new session would get and returns `'kept'` after pushing the update, or `'restart'` only when static (filesystem or process) policy differs. The reference design does not implement it.
- **`src/egress-lockdown.ts`: skip it under OpenShell, replace it with a compiled policy.**
  - Its mechanism (create a Docker `--internal` network, `docker network connect` the gateway container to it, `--network` for the agent) has no meaning for a `network=none` workload that cannot join any Docker network.
  - It is already effectively Docker-owned. `ensureEgressNetwork` is called from the Docker driver's registration (`src/drivers/index.ts:80-103`) and from the host-sweep singleton, which is a no-op unless a Docker spawn set `selectedAccess` (`src/egress-lockdown.ts:22,86-89`; `src/host-sweep.ts:96-99`).
  - The remaining job is the operator-facing flag. Under a `declarative` driver `NANOCLAW_EGRESS_LOCKDOWN=true` is silently inert, which breaks the "refuse rather than degrade" stance in `docs/SECURITY.md:195-199`. The decision set should say whether to log, refuse, or gate the flag on `capabilities().networkPolicy === 'topology'`.
  - The `NetworkAccessIntent` kinds do not map onto OpenShell: `runtime` names a Docker container to attach to a network and the workload cannot join one. `host` maps loosely to `host.openshell.internal`.
- **The reference design (v0.1.2, older base) differs from our current contract in four ways.**
  - Its `reconcileNetworkAccess` took `(access)` and returned `void` (`REF:src/drivers/types.ts:312`), with no per-handle `'kept' | 'restart'` verdict, and the OpenShell driver implements none.
  - It gates the credential gateway on `capabilities.networkPolicy === 'declarative'` and returns `{ endpoint: MODEL_HOST, target: { kind: 'host' } }` (`REF:.claude/skills/add-openshell/payload/src/gateway-providers/openshell.ts`). That stretches `kind: 'host'`, which in our fixtures means a host-gateway alias such as `host.internal` (`src/drivers/spec-fixture.ts:67`).
  - `'shared-private'` there means "gateway rule plus operator-listed egress rules plus attached providers", wider than the contract text "the gateway and nothing else" (`src/drivers/types.ts:132-139`).
  - It targets OpenShell v0.1.2 (`REF:versions.json`), which already had `network=none`, so that part of its design is sound.
- **Unverified.**
  - Non-DNS UDP and ICMP behaviour.
  - Docker-side DNS on `--internal` networks.
  - Whether a `v0.1.8` global policy can be restricted to a workspace.
  - Runtime behaviour: I read source and docs and did not run OpenShell.

## Details

### 1. NanoClaw's current network contract

**Contract surface** (`src/drivers/types.ts`):

- `NetworkAccessIntent` is `{ endpoint, target }`, where `target` is `host`, `runtime{identity}` or `session-container{role}` (lines 121-125).
- `SessionSpec.network: 'shared-private' | 'none'` is documented as "the containers of this session reach the gateway and nothing else. On Docker that is the egress-lockdown network machinery; other realizations enforce it declaratively. `capabilities.networkPolicy` tells the overlay which enforcement it got" (lines 129-139). `networkAccess` is line 141.
- `DriverCapabilities.networkPolicy: 'topology' | 'declarative'` (line 264).
- `sharedNetworkNamespace` (273-277) tells the gateway what proxy URL to put in the agent env (`src/gateway-providers/gateway-provider-registry.ts:42-46`).
- `auxiliaryContainers` (lines ~279-287). `src/container-runner.ts:495-500` refuses gateway-contributed containers when it is false.
- `reconcileNetworkAccess?(access, handle) => Promise<'kept'|'restart'|void>` (lines 258-259, 311-315).

**Docker realization:**

- `networkPolicy: 'topology'`, `sharedNetworkNamespace: false`, `auxiliaryContainers: true` (`src/drivers/docker-driver.ts:111-125`).
- `dockerNetworkArgs` (`src/drivers/index.ts:80-87`) returns `[]` for `session-container`. Otherwise it returns `--network <egress>` when lockdown is on, else `--add-host=<endpoint>:host-gateway` on Linux.
- Adopted containers are reconciled by `ensureEgressNetwork(access)` and `onEgressNetworkOnly(attachedNetworks())`, giving `'kept'` or `'restart'` (`src/drivers/index.ts:95-102`; `src/drivers/docker-driver.ts:129-131` and the adoption path at `139-170`).
- With auxiliary containers, Docker builds a per-session `--internal` network. The agent joins only that network, and aux containers keep the ordinary bridge as their uplink (`src/drivers/docker-driver.ts:13-17`, `:185-207`, `:847-849`).

**`src/egress-lockdown.ts`:**

- `ensureEgressNetwork` returns false when `EGRESS_LOCKDOWN` is off or no access has been seen (lines 86-88). It throws for non-`runtime` targets (90-92). It verifies the network is `--internal`, creates it if missing (96-102), and `docker network connect --alias <endpoint>`s the gateway container (106-116).
- `selectedAccess` is module state set only by that function (lines 22, 89).
- The host sweep calls it every tick (`src/host-sweep.ts:96-99`).
- `src/container-runner.ts:643-670` (`stopIfOffNetworkPolicy`) calls `driver.reconcileNetworkAccess?.()`, stops the session on `'restart'`, and fails closed (stops) on an exception.

**Defaults and docs:**

- Lockdown is off by default and documented as such (`docs/SECURITY.md:219-221`). The mechanism is described at `:179-217`, including "Only a `runtime` target can be locked down ... lockdown refuses rather than degrading" (`:195-199`). `docs/gateway-seam.md:112-116` says the same in two sentences.
- The in-tree credential gateways both return `runtime` targets (`.claude/skills/add-onecli/payload/src/gateway-providers/onecli.ts:322-326`; `.claude/skills/add-iron-proxy/payload/src/gateway-providers/iron-proxy.ts:386`).

**What the tests demand:**

- `src/drivers/conformance.test.ts:328-337` ("realizes session labels and network intent") only checks that `prepare()` resolves and lineage labels reach the runtime. There is no behavioural conformance assertion for isolation, for `network: 'none'`, or for `networkPolicy`.
- Only the Docker harness exists (`conformance.test.ts:108`, `harnesses = [dockerHarness()]`).
- Reconcile semantics are tested only against Docker (`src/drivers/docker-driver.test.ts:934-970`; `src/container-runner.egress-adoption.test.ts`).
- Outside type declarations, `spec.network` is read nowhere in `src` (`grep '\.network\b'`) and `capabilities.networkPolicy` is read nowhere. So today the contract for `'none'` and for `networkPolicy` is unexercised.

### 2. OpenShell v0.1.8: verification of the reported claims

| Claim | Verdict | Evidence |
|---|---|---|
| Workload runs `network=none` | Verified | `lib.rs:6322` (`network_mode: Some("none")`), `dns: ["127.0.0.53"]`, `dns_search: ["."]` (6323-6327), `extra_hosts: None` (6339), `cap_drop: ALL` (6309). `lib.rs:204`: "Workloads always use network=none". |
| Fence is enforced, not assumed | Verified | `validate_docker_outer_fence` (`lib.rs:3115-3143`) rejects anything but `network_mode=none` with no attached networks. Called at create (1817), on reconcile of running containers (1519), and at start (2516). Evidence is bound into the boundary generation (`isolation.rs:15-60`). |
| All TCP/DNS goes through the supervisor | Verified for TCP and DNS | Seccomp-notification broker "mediates every supported TCP and DNS operation" (driver README, "Runtime Model"). Socket families other than `AF_UNIX`, `AF_NETLINK(ROUTE)` and brokered `AF_INET`/`AF_INET6` fail `EPERM` (`best-practices.mdx`, "Seccomp Filters"). Startup "fails closed if nested seccomp notification is unavailable" (driver README, "Container Contract"). |
| Policy is default-deny | Verified | `default-policy.mdx` "Default Network Access"; `best-practices.mdx` "Deny-by-Default Egress". A global policy, then the sandbox's saved policy, then the image policy, then the default, in that precedence (`overview.mdx`). |
| Supervisor is also fenced | **No** | Supervisor `network_mode` is `host` (default) or `bridge` (`lib.rs:5221-5232`). The README states it "originates approved egress" and, in host mode, reaches the gateway's loopback listener. SSRF rules still apply to supervisor-originated connections (below). |

SSRF and host reach (`docs/security/best-practices.mdx`, "SSRF Protection"; `schema.mdx`):

- Loopback, link-local (including `169.254.169.254`) and unspecified addresses are always blocked.
- Private RFC 1918 addresses are reachable only by exact hostnames declared in user policy, or via `allowed_ips`.
- Kubernetes and etcd control-plane ports are blocked on exact-host rules.
- `host.openshell.internal` is the exception that reaches host services (README: "policies can reach host services without a Docker bridge").
- On native Linux in host mode, the alias resolves to the host's loopback.

Other facts from the sources:

- Per-sandbox policy: policy is a field of `SandboxSpec` (`proto/openshell.proto:1087`). `overview.mdx` says network rules "can change while it runs".
- DNS is answered by the supervisor with placeholder addresses for hosts named in rules, TTL at most 30 seconds, and AAAA gets an empty answer (`network-rules.mdx`, "Allow Native TCP").
- `v0.1.2` (the reference design's target) had the same fence: `OS@v0.1.2:.../lib.rs:3008-3015` (check), `:4883` (supervisor-side staging container, `network_mode none`), `:5797` (workload), with supervisor `host` mode (`:4961`).
- Docker Desktop needs host networking enabled for host-mode supervisors (driver README, "Gateway session and TLS").

### 3. Guarantee-by-guarantee mapping

| NanoClaw guarantee (today) | Under OpenShell v0.1.8 Docker driver | Status |
|---|---|---|
| Session reaches only its credential gateway | Default-deny allowlist; equals "gateway only" only if the compiled policy contains just that rule | Weaker: policy-dependent, not structural |
| No bypass of the proxy by ignoring `HTTPS_PROXY` | `network=none` plus seccomp mediation, verified by OpenShell at create, reconcile and start | Provided |
| Sessions cannot reach each other | No network device in any workload | Provided |
| Session cannot reach the host | Only via an explicit `host.openshell.internal` rule; supervisor is on the host network | Provided by default, widened by a single rule |
| Session cannot reach auxiliary gateway containers other than via the intended hop | There are no auxiliary containers; extra hosts are reachable only by policy | Not applicable; the feature is gone |
| Agent cannot undo it | Non-root, caps dropped, Landlock `/.openshell`, seccomp; no policy-editing credentials in the workload | Provided |
| Operator cannot accidentally leave egress open | Operator edits, advisor approvals, provider rules and global policy can all widen it at runtime | Weaker |
| DNS | Mediated, per-rule; wildcard rules open a label channel | Different; arguably stronger than Docker |
| Policy scope | Per-sandbox, but a global policy overrides all; shared gateway-wide admin plane | Weaker: policy is gateway-wide in the global case; admin identity is wider |
| Adoption after host restart converges to current policy | OpenShell hot-reloads network rules; static filesystem/process policy is fixed at start | Needs a driver implementation (see below) |

### 4. What the driver must do to satisfy the contract honestly

1. **Capabilities.** Report `networkPolicy: 'declarative'`. `auxiliaryContainers: false` follows from the two-container model. `sharedNetworkNamespace: false` is right (the workload has no network, so the credential gateway is reached by a mediated name, never `localhost`).
2. **Refuse, never ignore.** Refuse auxiliary containers and `session-container` targets in `prepare()`. For `runtime` targets there is nothing to attach a Docker network to: either reject, or have the contribution carry a `host:port` that policy can name. The current intent has no port, so the second option needs a contract change.
3. **Realize `network`.**
   - `'shared-private'` compiles to a policy with a rule for `networkAccess.endpoint` and nothing else, plus the unavoidable provider rules. The contract text must be updated to say what "nothing else" means once providers attach.
   - `'none'` compiles to no `network_policies` and attaches no providers.
4. **Reconcile.** Implement `reconcileNetworkAccess(access, handle)` so adoption is not silent. The natural verdict is: apply the target network policy to the running sandbox and return `'kept'`, or return `'restart'` if the static parts differ or a global policy is present. This is a decision, not a requirement of OpenShell.
5. **Verify the gateway posture at startup.** `ensureReady` could check there is no permissive global policy and that auto-approval and the policy advisor are off, since these are what the "gateway only" guarantee now depends on. (My suggestion; OpenShell has no such check built in.)
6. **Do not run `src/egress-lockdown.ts`.** There is nothing for it to configure. Gate it on capabilities rather than on driver identity (the rule in `src/drivers/index.ts:1-8`).

### 5. The reference design, point by point

- **Network realization:** `REF:src/drivers/openshell/driver.ts:183-209` (capabilities), `:233-242` (refuse auxiliaries and `session-container`), `REF:src/drivers/openshell/policy.ts:227-251` (rules compiled only when `spec.network === 'shared-private'`; the gateway rule name and `GATEWAY_RULE_NAME`).
- **Policy file:** `docs/openshell.md:128-163` is the operator-owned per-group policy file that supplies ports, hosts and binaries (hosts the intent cannot express).
- **Model provider route:** `docs/openshell.md:70-81`. The Claude credential is an OpenShell provider; the model-host rule is contributed by the provider, not by `networkAccess`.
- **No reconcile:** `grep reconcileNetworkAccess` in the reference's OpenShell driver finds nothing. The reference's own base type is `reconcileNetworkAccess?(access): Promise<void>` (`REF:src/drivers/types.ts:312`), which cannot express the verdict our contract uses.
- **Gateway-wide gateway settings:** `docs/openshell.md:111-118`. NanoClaw's session mounts need `enable_bind_mounts`, `allow_driver_config` and `resource_admission` off in `gateway.toml`, so "these are gateway-wide settings" that "apply to every sandbox on that gateway". At v0.1.8 the Docker driver README still says bind mounts are disabled by default, and "raw bind mounts have no supported label resolver and are denied under enforcement" ("Runtime Model" and "Driver Config Mounts"). This is not a network issue but bears on the policy-is-gateway-wide concern.
- **Where it matches us:** it already treats `networkPolicy` as the gate (`REF:.../openshell.ts`) and never validates-then-ignores aux containers, which is the contract we have.

## Open questions / implications for the decision set

1. **Redefine the contract.** "Reach the gateway and nothing else" (`types.ts:132-139`) cannot be literally true under OpenShell once providers attach rules. Decide whether to word it as "reach only destinations the compiled effective policy allows, which includes exactly the gateway endpoint and the declared providers", and make `networkPolicy` carry that meaning.
2. **Extend or replace `NetworkAccessIntent`.** An OpenShell rule needs port and binaries, and `runtime{identity}` is Docker-shaped. Options: add `port`/`binaries`, add a kind such as "mediated hostname", or keep the intent minimal and let operator config supply the rest as the reference design does.
3. **Where does the credential gateway live?** If OpenShell is both session driver and credential gateway, `networkAccess` is nearly vestigial: the provider rules carry the route. If OneCLI or Iron Proxy stay as the credential gateway under an OpenShell session driver, the workload reaches them only through a `host.openshell.internal:<port>` rule, and the `runtime`-only egress-lockdown path is inapplicable.
4. **What to do with `NANOCLAW_EGRESS_LOCKDOWN` under a declarative driver.** Options: refuse to start, warn, or document as inert. Silent inertness contradicts `docs/SECURITY.md:195-199`.
5. **Policy governance.** Decide whether NanoClaw must assert, at startup, that no global policy, auto-approval or policy advisor is active, and who holds OpenShell admin credentials. On a local gateway without OIDC, any authenticated CLI user is Platform Admin.
6. **`reconcileNetworkAccess` semantics for hot-reloadable policy.** Is convergence by policy push (`'kept'`) acceptable, or must a drifted sandbox restart? Static policy (filesystem, process) cannot change without a restart.
7. **Make the contract testable.** Today nothing exercises `'none'` or `networkPolicy`, and only one driver is in the conformance harness. A declarative conformance case ("a spec with `'none'` yields no network rules and no providers") would pin the new meaning.
8. **Version risk.** OpenShell is pre-1.0 and the Docker driver surface changed between v0.1.2 and v0.1.8 (two-container model, `supervisor_network_mode`, resource admission). The decision set should pin the version and name the fields relied on.
