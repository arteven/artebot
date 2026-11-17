# OpenShell v0.1.8: observing and deciding pending rule approvals

Research for map #1, ticket #3. Sources are OpenShell tag `v0.1.8` (commit
`f3d976590d3eb1379690a2abaf0f0e26c21d487d`), read from a shallow clone and never built or run.
`B` below = `https://github.com/NVIDIA/OpenShell/blob/v0.1.8/`. Claims I could not confirm
from source are marked UNVERIFIED. Terms: *credential gateway* is NanoClaw's seam; *OpenShell
gateway* is OpenShell's control-plane service; *OpenShell provider* is a stored credential.

## Answer in brief

1. OpenShell has no "held request awaiting approval". A blocked connection is denied at once;
   OpenShell records a **draft rule** (a "chunk") that a human approves or rejects. After approval
   the agent must retry. The approval is a standing rule for the sandbox, not a one-request grant.
2. The surface is gRPC (`GetDraftPolicy`, `ApproveDraftChunk`, `RejectDraftChunk`, ...). The CLI
   (`openshell rule ...`) prints coloured human text; **there is no JSON output**.
3. **Observation is polling only.** A stream message exists (`DraftPolicyUpdate`) but nothing in the
   v0.1.8 tree emits it. There is no cross-sandbox listing: poll per sandbox.
4. A pending chunk names binary, host, port(s), optional L7 method/path, rationale, risk findings.
   It has **no explicit credential/OpenShell-provider field**; credential risk shows up only as
   free-text prover findings.
5. Approvals live as long as the sandbox object (they survive stop/start) and are **deleted with the
   sandbox**. Pending chunks have no TTL that I found.
6. No per-request credential hold exists. The nearest hook (supervisor middleware) is capped at 30 s
   per call, far too short for a human.

## 1. Approval surfaces

### 1.1 gRPC (authoritative)

Service `openshell.v1.OpenShell`, `B proto/openshell.proto`:

| RPC | Line | Purpose | Auth (from proto options) |
|---|---|---|---|
| `GetDraftPolicy` | 694 | list chunks for **one** sandbox; `status_filter` of `pending`/`approved`/`rejected`/empty | `config:read`, user role |
| `ApproveDraftChunk` | 703 | merge one chunk into the sandbox's active policy | `config:write`, **admin** role |
| `RejectDraftChunk` | 713 | reject with optional `reason` | `config:write`, admin |
| `ApproveAllDraftChunks` | 723 | bulk; skips security-flagged unless forced | admin |
| `EditDraftChunk` / `UndoDraftChunk` / `ClearDraftChunks` | 733 / 742 / 751 | narrow, revert, drop pending | admin |
| `GetDraftHistory` | 761 | decision history | `config:read` |
| `WatchSandbox` | 673 | stream of status, logs, platform events, `DraftPolicyUpdate` | `sandbox:read` |

Request shapes: `GetDraftPolicyRequest` (3666: `sandbox`, `workspace_scope`, `status_filter`);
`ApproveDraftChunkRequest` (3688: `sandbox`, `chunk_id`, `review_token`, optional `request_id`);
`RejectDraftChunkRequest` (3710: `sandbox`, `chunk_id`, `reason`, optional `request_id`).
`request_id` is a nonzero UUID giving durable at-most-once admission; successful results replay for
24 h (`B docs/sdk/api-errors.mdx`, lines ~107-150). Auth modes: mTLS (default), OIDC, edge JWT
(`B docs/how-it-works/gateways/authentication.mdx`).

### 1.2 CLI (`openshell rule`)

- The `rule` command is `hide = true` (`B crates/openshell-cli/src/main.rs:578`); subcommands
  `get`, `approve`, `reject`, `approve-all`, `clear`, `history` (`main.rs:2093-2152`). It is
  documented in the advisor page (`B docs/how-it-works/policies/advisor.mdx:114-151`).
- `rule get <sandbox> --status pending` has **no `-o/--output` flag** (`DraftCommands::Get` takes only
  name and `--status`). It prints coloured text, one block per chunk with `Chunk:`, `Status:`,
  `Rule:`, `Binary:`, `Confidence:`, `Rationale:`, `Security:`, `Prover:`, `Application:`,
  `Candidate:`, `Endpoints:`, `Binaries:`, `Hits:` lines (`B crates/openshell-cli/src/run.rs:6731-6839`).
  This **invalidates the ticket's "CLI JSON" assumption.**
- `rule approve` first calls `GetDraftPolicy` to fetch the chunk's `review_token`, then
  `ApproveDraftChunk` (`run.rs:6842-6889`). It leaves `request_id` empty.
- Precedent: nanoco-bot/nanoclaw scrapes this text (`parseRuleChunks` in
  `.claude/skills/add-openshell-console/scripts/openshell-ops.ts`) and its credential-gateway
  `approvals.subscribe` is a no-op that only waits for abort
  ([`openshell.ts` L55-62](https://github.com/nanoco-bot/nanoclaw/blob/main/.claude/skills/add-openshell/payload/src/gateway-providers/openshell.ts));
  its `docs/openshell-operations.md` ("Blocked requests") says NanoClaw sends no card and approvals
  are made in OpenShell. That fork never solved this ticket's problem.

### 1.3 SDKs

| SDK | Draft/approval support in v0.1.8 |
|---|---|
| Go (`B sdk/go/openshell/v1/policy_client.go`) | Curated: `GetDraft`, `ApproveDraftChunk`, `RejectDraftChunk`, `ApproveAllDraftChunks`, `EditDraftChunk`, `ClearDraftChunks`, `GetDraftHistory`. Module deprecated in favour of `github.com/ai-openshell/sdk-go` ([v0.1.8 release notes](https://github.com/NVIDIA/OpenShell/releases/tag/v0.1.8)) |
| TypeScript (`B sdk/typescript/src/client.ts`) | No curated draft methods (only a comment at L893). Use `client.raw` with `@nvidia/openshell-sdk/raw` types (`B docs/sdk/typescript.mdx`, "Use the Raw Client") |
| Python | No draft wrapper in-tree; generated stubs only (`B docs/sdk/python.mdx`, "Call Generated RPCs"). Now published from `ai-openshell/sdk-python`; a code search there for "draft" finds no source hit. UNVERIFIED beyond that search |
| Rust (`B crates/openshell-sdk/src/client.rs`) | No draft wrapper (L1593/L1631 only skip the stream variant). UNVERIFIED whether the crate exposes raw access |

For a Node host the realistic options are the TS SDK's raw client or scraping CLI text.
UNVERIFIED: whether the TS SDK's version tracks the OpenShell gateway version.

### 1.4 Event stream: none usable

- `SandboxStreamEvent.payload` includes `draft_policy_update` (`openshell.proto:2187-2201`) with
  `draft_version`, `new_chunks`, `total_pending`, `summary` (`3618-3627`).
- **No server code emits it.** A repo-wide grep for `DraftPolicyUpdate` in `*.rs/*.go/*.ts/*.py`
  finds only two match arms that ignore it (`crates/openshell-sdk/src/client.rs:1631`,
  `crates/openshell-cli/src/run.rs:1010`). So `WatchSandbox` cannot be relied on to signal new
  chunks in v0.1.8. The shipped TUI polls: 2 s tick, `GetDraftPolicy` for the open sandbox plus
  per-sandbox draft counts (`crates/openshell-tui/src/lib.rs:124,381-398`).
- Logs: the gateway log records `CONFIG:APPROVED/REJECTED` (with `chunk_id`, `actor`);
  `CONFIG:PROPOSED` appears **only for agent-authored proposals**, not OpenShell's own drafts
  (`advisor.mdx:302-319`). `WatchSandbox` `follow_logs` with `resume_after_cursor` could carry those,
  but they are not a complete trigger.
- `GetDraftPolicy` is per sandbox. `listPending` therefore means `ListSandboxes` (`openshell.proto:83`)
  then one `GetDraftPolicy(status_filter="pending")` per sandbox.
- Latency of a new chunk: OpenShell's own blocked-connection drafts come from an aggregator that
  flushes every 10 s (`crates/openshell-sandbox/src/activity_aggregator.rs:20`); agent proposals via
  `policy.local` are submitted directly.

## 2. What a pending rule carries

`PolicyChunk` (`openshell.proto:3557-3615`), embedding `NetworkPolicyRule`/`NetworkEndpoint`
(`B proto/sandbox.proto:63,140,352`):

| Fact | Field | Notes |
|---|---|---|
| Sandbox | **not in the chunk** | Known only from the RPC's `sandbox` argument. Our driver must own the sandbox-name to session mapping (sandbox labels at create time, or the name itself) |
| Binary | `binary` (16), `proposed_rule.binaries[].path` | Absolute path |
| Host / ports | `proposed_rule.endpoints[].host`, `port`/`ports` | Host may be a glob; `allowed_ips` may be present |
| L7 | `endpoints[].protocol` (`rest`, `graphql`, `mcp`, ...), `rules[].allow{method,path}`, `deny_rules`, `path`, `access` preset | OpenShell's own drafts are one binary to one host:port (`advisor.mdx:53-59`); agent proposals may carry method/path |
| Why | `rationale`, `rule_name`, `confidence`, `hit_count`, `first/last_seen_time`, `stage` (`initial`/`refined`), `supersedes_chunk_id` | `rationale` is agent-written for agent proposals: untrusted text |
| Risk | `security_notes`, `validation_result` (prover shorthand such as `credential_reach_expansion: <host:port> via <bin>`, `prover: no new findings`, `validation unavailable`), `application_error` | Findings: `link_local_reach`, `l7_bypass_credentialed`, `credential_reach_expansion`, `capability_expansion` (`advisor.mdx:202-207`; `crates/openshell-prover/src/report.rs:61`) |
| Review binding | `review_token`, `current/candidate_effective_policy(_hash)` | Token changes when live inputs change (e.g. providers changed); approval then fails `FAILED_PRECONDITION "refetch and review again"` (`run.rs:6894-6903`) |
| Time / id | `id`, `created_time`, `status`, `decided_time`, `rejection_reason` | **No expiry field** |

**Credential / OpenShell provider involvement is implicit.** Providers inject credentials as
placeholders the proxy resolves only when network policy allows the binary and destination and the
destination is in the provider profile's endpoints (or a policy endpoint explicitly bound, for an
endpointless profile) (`B docs/how-it-works/providers/overview.mdx:447-476`). So approving a rule
for a host in a provider's endpoints **grants that binary use of the credential**; the prover
reports it as a finding string only. Credential values are never in chunks (`openshell.proto:3611`).
To say "credentialed" structurally, the adapter must also read attached providers and their profile
endpoints (`ListSandboxProviders` L132, `GetProviderProfile` L346); that is derivation, not an
API fact.

Content can change under a pending chunk: mechanistic drafts for the same `host|port|binary` fold
into one row with `hit_count++` (`SubmitPolicyAnalysisRequest.analysis_mode`, `openshell.proto:3637-3644`),
a `refined` chunk may supersede an `initial` one, and up to 32 pending proposals are rechecked on
each policy change (`crates/openshell-server/src/grpc/policy.rs:1209`), changing `review_token` and
risk text. A card's binding must be rebuilt from a fresh fetch before deciding.

## 3. Deciding

- **Programmatic**: `ApproveDraftChunk(sandbox, chunk_id, review_token[, request_id])` /
  `RejectDraftChunk(sandbox, chunk_id, reason[, request_id])`. Approve accepts `pending` or `rejected`
  chunks and returns `FAILED_PRECONDITION` otherwise (`crates/openshell-server/src/grpc/policy.rs:6200-6204`).
  Idempotent retry is available via `request_id` (24 h replay).
- **Effect**: the rule is merged into the sandbox's **own** policy as a separate rule (provider-contributed
  rules untouched), a new policy version is stored, the sandbox loads it live, and **connections opened
  under the old rules are closed** so a retry uses the new rule (`advisor.mdx:275-296`). Rejection
  sends `reason` plus findings back to a waiting agent (`/v1/proposals/{id}/wait`).
- **Lifetime**: stored per sandbox ID. Stop/start retain policies (`B docs/how-it-works/sandboxes/overview.mdx:988-1004`).
  `DeleteSandbox` deletes policy revisions and draft chunks for that ID
  (`crates/openshell-server/src/compute/mod.rs:6352-6380`), so **an approval does not survive sandbox
  recreation**. nanoco-bot's doc says the same ("lasts until the sandbox is recreated"). Keeping it
  across recreation means adding the endpoint to the creation-time policy, outside the approval API.
- **Held connection**: none. The blocked request "stays denied, so retry it after OpenShell approves the
  draft" (`advisor.mdx:57-59`); for inspected HTTP the denial body points the agent at `policy.local`.
  The agent-side wait is `GET http://policy.local/v1/proposals/{id}/wait?timeout=` (cap 300 s, re-issued
  on timeout; `crates/openshell-supervisor-network/src/policy_local.rs:53-58`), available only when the
  policy advisor is enabled (`agent_policy_proposals_enabled`, off by default).
- **Timeouts**: I found no server-side TTL or expiry on pending chunks (`grpc/policy.rs` expiry hits are
  all credential expiry). Pending chunks wait indefinitely. UNVERIFIED for the persistence layer
  (sqlite/postgres) beyond that.
- **Auto mode**: `proposal_approval_mode = auto` approves chunks with no prover finding and no flagged
  destination, including OpenShell's own drafts, so public hosts open without review; default `manual`;
  a gateway-wide `manual` overrides sandbox values (`advisor.mdx:153-190`). `sandbox create` also takes
  `--approval-mode`.
- **Blockers**: while a global policy is active no proposal can be approved, even automatically
  (`advisor.mdx:149`). Loopback, link-local and metadata destinations cannot be approved.

## 4. Per-request credential holds

No. Approvals are rules, never individual requests.

- The only request-granularity hook is **supervisor middleware**
  (`B docs/extensibility/supervisor-middleware/index.mdx`): allow / deny / change per HTTP request, run
  after the network-policy check and **before credential injection** (middleware never sees
  credentials). The RPC timeout is 500 ms by default, configurable from 10 ms to 30 s
  (`configure.mdx:55-56`; `B proto/supervisor_middleware.proto:86-90`); failure or timeout blocks by
  default. A 30 s ceiling cannot host a chat-card round trip. UNVERIFIED: whether middleware sees
  enough request metadata (host, method, path) to build a card.
- Gateway interceptors (`B docs/extensibility/gateway-interceptors.mdx`) hook control-plane gRPC, not
  sandbox egress.
- So OpenShell cannot reproduce OneCLI's "hold this credentialed call until a human decides". The closest
  approximation is: the adapter treats each new chunk as one approval, with rule-level (not
  request-level) scope.

## 5. Mapping onto our contract

Slots from `src/gateway-providers/gateway-provider-registry.ts` (`approvals.*`); flow in
`src/gateway-approval-coordinator.ts` (cited as `coordinator:<line>`).

| OpenShell fact | Slot | Implication |
|---|---|---|
| Chunks persist in the OpenShell gateway until decided or sandbox deletion; pending is re-enumerable | `durable: true` | **Choose durable.** The coordinator denies non-durable requests with `createdAt < startedAt` (`coordinator:406`), so a host restart would mass-deny; durable maps "no decision yet" to `unavailable`, which here means "leave the chunk pending" (no OpenShell call) |
| No stream emits chunk events; `GetDraftPolicy` is per sandbox | `subscribe` | A polling loop (interval is our choice; the TUI uses 2 s): `ListSandboxes` filtered to this install, then `GetDraftPolicy(pending)` per sandbox; translate each unseen chunk to a `GatewayApprovalRequest`, await `decide`, then call Approve/Reject. Throw on RPC failure so the coordinator marks the bridge unavailable (`coordinator:179-205`) |
| Same per-sandbox enumeration | `listPending` | Same enumeration, no side effects. The coordinator uses it for restart recovery and to resolve rows whose chunk vanished (`coordinator:711-726`); a vanished chunk means decided elsewhere or sandbox deleted |
| `ApproveDraftChunk` / `RejectDraftChunk`, `request_id` replay | `decide(requestId, decision)` | `approve`: refetch chunk, check status and binding, `ApproveDraftChunk` with fresh `review_token` and a `request_id` derived from the NanoClaw approval id. `deny`: `RejectDraftChunk` with a reason. `unavailable`: no call, return true. Return false on `FAILED_PRECONDITION` (stale token), then re-card |
| API addresses a chunk by `sandbox` + `chunk_id`; global uniqueness of chunk ids UNVERIFIED | `request.id` | Use `<sandbox>/<chunk_id>` |
| Sandbox is not in the chunk | `agentGroupId`, `sessionId`, `runtimeIdentity` | The coordinator rejects requests whose session is not active or whose `runtimeIdentity` differs (`coordinator:333-358`). The driver must record `gatewayRuntimeIdentity(key)` on the sandbox (labels) so `subscribe` can resolve it. Chunks of sandboxes this install does not own must be skipped untouched (`scope.ownsAgentGroup`) |
| binary, host, ports, L7 rules, rationale, security_notes, validation_result | `summary`, `destination`, `displayFields` | `destination.host` from the first endpoint; `destination.method` only if exactly one REST allow rule exists, else omit; leave `sendsPayload` unset. `rationale` is untrusted agent text: bound it, never let it affect authorization. Put binary, ports, L7 rules and prover findings in `details`/`displayFields` |
| Approval is a standing sandbox rule, not one request | card text | **Conflicts with the common card** stating approval "applies to one request" (`docs/gateway-seam.md`, "Approval presentation"). Needs different wording or a gateway-specific renderer |
| These are explicit holds, not default model-traffic holds | `trigger` | Use `policy`, so default-hold exemptions (model domains, read-only hosts, uncredentialed reads) never apply (`gateway-seam.md`, "Default model-traffic approvals") |
| No expiry | `expiresAt` | Leave unset; the coordinator applies its own deadline (`timeoutMs`, ceiling 60 min, `coordinator:45,370`). After expiry a durable adapter answers `unavailable` and the chunk stays pending in OpenShell; the next poll would re-card it (question 1 below) |
| No per-request holds; credential use is implicit in rule reach | `credentialScope` | Only consulted for `trigger: default` GET/HEAD holds (`gateway-seam.md`, "Uncredentialed reads"), which OpenShell never produces. Safe choice: omit it. If ever implemented, derive from attached provider profile endpoints (over-report, never under-report), not from the approval API |
| OpenShell gateway reachability; `Health` RPC (`openshell.proto:25`) | availability, `subscribe` supervision | A failed poll ends `subscribe` and closes session admission, which is the desired fail-closed behaviour. `availability.publish/read` only matter if approvals and session admission run in separate processes |
| `agent_policy_proposals_enabled`, `proposal_approval_mode`, global policy | install/setup | Setup should pin `proposal_approval_mode=manual` gateway-wide (blocks `auto` per sandbox) and decide whether to enable agent proposals; an active global policy disables approvals |
| Approve/Reject need admin role / `config:write` | host credentials | The NanoClaw host's OpenShell identity can alter any sandbox's egress policy; treat it as privileged |

## 6. New questions and invalidated assumptions

Invalidated:

- "CLI JSON" does not exist for `rule get`; the command is hidden and text-only.
- "Event stream or only polling": polling only in v0.1.8 (`DraftPolicyUpdate` has no emitter).
- A decision does **not** release a held connection; it edits policy and the agent retries.
- "One request" card semantics do not hold; approvals are standing, sandbox-lifetime rules.

New sharp questions for the map:

1. **Re-card loop.** After the coordinator expires a card, the chunk stays `pending` in OpenShell. Should
   `subscribe` remember "expired, do not re-present" (for how long), reject the chunk, or re-card?
2. **Agent-visible outcome.** With no held connection, who tells the agent to retry? Rely on `policy.local`
   (needs `agent_policy_proposals_enabled` and the guide OpenShell injects) or a NanoClaw on-wake
   message after `decide`?
3. **Client choice.** TS SDK raw client, CLI text scraping, or our own gRPC client; the version pin and
   conformance run must cover whichever is picked.
4. **Persistence across recreation.** Do approved rules need promotion into a NanoClaw-owned per-group
   policy so a recreated sandbox keeps them (nanoco-bot's "Always allow")? Who stores it?
5. **Sandbox ownership and naming.** How are names and labels derived so a chunk maps to
   `(agentGroupId, sessionId)` and foreign sandboxes are ignored?
6. **Rule-level credential grants.** Is a standing approval on a provider-covered host acceptable as
   "one approval", given it grants that binary ongoing use of the credential?
