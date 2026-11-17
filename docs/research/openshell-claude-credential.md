# How a Claude credential reaches the agent through an OpenShell provider

Ticket: arteven/artebot#4 (wayfinder map #1). Target: OpenShell v0.1.8, agent provider `claude`.
Date: 2026-11-17. Terms follow CONTEXT.md: "OpenShell provider" is OpenShell's credential bundle,
"agent provider" is NanoClaw's `claude`/`codex`/... seam, "credential gateway" is NanoClaw's seam.

Sources (all read, nothing executed):
- OS = NVIDIA/OpenShell tag v0.1.8 (https://github.com/NVIDIA/OpenShell/tree/v0.1.8), release notes
  https://github.com/NVIDIA/OpenShell/releases/tag/v0.1.8
- NB = nanoco-bot/nanoclaw (https://github.com/nanoco-bot/nanoclaw), the existing OpenShell integration
- CC = Claude Code docs, https://code.claude.com/docs/en/authentication and `/en/network-config`
- Repo paths are relative to this checkout (HEAD 96ba5dc9).

## Short answers

1. API key: OpenShell provider profile, credential key `ANTHROPIC_API_KEY`, header placement `x-api-key`
   declared explicitly, endpoint `api.anthropic.com:443`. OS ships this as `providers/anthropic.yaml`
   and `providers/claude-code.yaml` (copy and edit, do not import unchanged).
2. OAuth token: no profile ships for it. Needs a custom profile, credential key
   `CLAUDE_CODE_OAUTH_TOKEN`, `auth_style: bearer`, `header_name: authorization`, same host. NB generates
   exactly this.
3. Inference routing is not the path. v0.1.8 removed managed inference routes and `openshell inference`.
   The agent calls `https://api.anthropic.com` natively and the proxy substitutes the credential.
4. The body-placeholder 403 guards against stale or unbound placeholders in a request body. A normal SDK
   request never trips it. It can trip if a placeholder leaks into conversation history (section 4).
5. NanoClaw today sets no Anthropic credential env for the `claude` agent provider. A credential gateway
   contribution (OneCLI) supplies `ANTHROPIC_BASE_URL` plus a stub bearer. Under OpenShell the container
   needs only the placeholder env OpenShell itself injects. NanoClaw contributes nothing
   (UNVERIFIED end to end, see Open questions).

## 1. The mechanism in v0.1.8

An OpenShell provider holds named credentials. Inside the sandbox each credential appears as an env var
whose value is an opaque placeholder, `openshell:resolve:env:v<revision>_<KEY>` (bare form), or
`s<handle>_<KEY>` when `stable_placeholder: true` (OS `docs/how-it-works/providers/overview.mdx`,
`crates/openshell-core/src/secrets.rs`). The supervisor proxy swaps the placeholder for the real value
just before forwarding upstream. The sandboxed process never sees the secret. The supervisor also sets
CA-trust env for the intercepting proxy: `NODE_EXTRA_CA_CERTS`, `DENO_CERT`, `SSL_CERT_FILE`,
`REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO` (OS `crates/openshell-sandbox/src/child_env.rs`).
The Claude CLI is Node and the agent-runner is Bun, so `NODE_EXTRA_CA_CERTS` and `SSL_CERT_FILE` are the
relevant ones. NanoClaw needs no CA env of its own (UNVERIFIED for Bun specifically).

A request carrying a credential passes three independent checks (OS `how-it-works/providers/profiles.mdx`,
`policies/network-rules.mdx`):

1. Network policy: the calling binary (real executable path, symlinks not followed, hashed on first use;
   a listed binary also covers processes it spawns) may reach host and port.
2. Credential binding: host, port and path fall inside the profile's endpoints. Every credential in a
   profile is bound to the profile's full endpoint set.
3. Placement: the placeholder sits where the profile declared (header, query parameter or path slot), or
   an explicit body rewrite is enabled.

### v0.1.8 placement change (the breaking part)

Release note, PR #4886: static credentials without placement metadata now resolve only in the
`Authorization` header or through an explicit body/WebSocket rewrite. `x-api-key`, query parameters and
path slots need an explicit declaration. Consequences:

- Upgrade the OpenShell gateway before the sandbox supervisor.
- Imported profiles keep their old content. Re-import after fixing the YAML. The example YAML in the repo
  does not update the catalog by itself.
- A mismatch yields 403 `credential_placement_mismatch` or `credential_endpoint_mismatch`
  (OS `policies/manage-policies.mdx`, error table near line 342).

## 2. API key path

Profile shape (OS `providers/anthropic.yaml`, which sets the header explicitly):

```yaml
id: anthropic            # NB uses nanoclaw-claude-api-key
credentials:
  - key: ANTHROPIC_API_KEY
    auth_style: header
    header_name: x-api-key
endpoints:
  - host: api.anthropic.com
    port: 443
    protocol: rest
    access: full
    enforcement: enforce
binaries: [ ... ]        # must name the real paths in OUR image
```

- Hosts: `api.anthropic.com:443` is sufficient for inference with an API key.
- The shipped example also lists `statsig.anthropic.com` and `sentry.io`. Those are stale against CC
  network docs, which list `api.anthropic.com`, login hosts, and optional Datadog intake hosts for
  telemetry. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` disables the optional traffic (CC
  `/en/network-config`). It is not set anywhere in `src/`, `container/` or `setup/` today (grep).
- Env the CLI sees: `ANTHROPIC_API_KEY=openshell:resolve:env:v<n>_ANTHROPIC_API_KEY`.
- Claude Code precedence (CC authentication): `ANTHROPIC_AUTH_TOKEN` (Bearer), then `ANTHROPIC_API_KEY`
  (`X-Api-Key`, always used with `-p`), then `apiKeyHelper`, then `CLAUDE_CODE_OAUTH_TOKEN`, then
  subscription OAuth.
- UNVERIFIED: that the CLI does no format validation on the key before sending. NB `docs/openshell.md`
  says a placeholder works on OpenShell v0.1.2. Nobody has shown it on v0.1.8 with claude-code 2.1.321
  (pinned in `container/cli-tools.json`).

## 3. OAuth (subscription) path

- Token: `CLAUDE_CODE_OAUTH_TOKEN`, a one-year token from `claude setup-token`, inference only (CC
  authentication). NB wraps capture in `.claude/skills/add-openshell/scripts/capture-claude-token.sh`.
- Profile: OS ships none. NB generates it in `src/drivers/openshell/model-provider.ts`:
  `MODEL_CREDENTIAL_ENV.oauth = 'CLAUDE_CODE_OAUTH_TOKEN'`, `auth_style: bearer`,
  `header_name: authorization`, profile id `nanoclaw-claude-oauth`, endpoint `api.anthropic.com:443`.
  Bearer in `Authorization` satisfies the v0.1.8 placement rule even with default placement.
- UNVERIFIED: the exact header the CLI sends for `CLAUDE_CODE_OAUTH_TOKEN` (CC docs do not state it, the
  bearer assumption comes from NB) and any extra `anthropic-beta` header. The proxy only touches the
  declared header, so extra headers do not matter.
- UNVERIFIED: whether an env-token session contacts `platform.claude.com`, `claude.ai` or `sso.claude.com`
  (login hosts per CC network-config). With a pre-issued token it should not. If it does, add them to the
  profile endpoints, which also binds the credential to them.
- Policy risk, separate from mechanics: Anthropic's legal and compliance page directs Agent SDK and product
  developers to API keys and does not permit routing or intermediating Free/Pro/Max credentials for other
  users or storing Claude.ai credentials. A user running unmodified Claude Code on their own subscription
  is allowed. A personal single-user install is the defensible case, anything multi-user is not.
  Source: https://code.claude.com/docs/en/legal-and-compliance, read at research time, re-check before
  shipping. An OpenShell placeholder changes where the token lives, not whose token it is.

## 4. Inference routing and the body-placeholder 403

Inference routing. OS `docs/how-it-works/inference.mdx` (v0.1.8): managed inference routes and the
`openshell inference` commands are gone. The workload calls the native endpoint with its own model name
and timeout. `inference_capable: true` in a profile is informational metadata only
(`profiles.mdx` ~L547). A custom base URL needs its own endpoint-bearing profile. Verdict: native
endpoint plus a profile. Leave `ANTHROPIC_BASE_URL` unset.

Body-placeholder 403. `credential_placeholder_in_request_body` fires when a request body contains a
placeholder of a known credential key that is invalid, stale, revoked, unbound to the endpoint, or in
legacy form (OS `crates/openshell-core/src/secrets_body.rs`,
`crates/openshell-supervisor-network/src/l7/relay.rs`). Properties:

- Valid, currently issued placeholders in a body pass through unchanged and are never resolved, because
  `request_body_credential_rewrite` defaults to false (`policies/schema.mdx` ~L174). Unknown literals
  also pass.
- `request_body_credential_rewrite: true` makes the proxy resolve placeholders in UTF-8 JSON, form or text
  bodies. Do not enable it on the Anthropic endpoint: any text the model emits could then spend the
  credential. OS `skills/debug-inference/SKILL.md` advises against enabling it to send tool output.
- Meaning for the SDK: every `/v1/messages` call carries the whole conversation in its body. The credential
  rides in a header, so a clean session never trips the rule. It trips only if the agent prints an env var
  (`env`, `printenv`, an error echoing `ANTHROPIC_API_KEY`), which puts a placeholder into tool output and
  so into history. While valid, the literal text passes. After rotation (`provider update --credential KEY
  --wait` bumps the revision) the old placeholder is stale and later turns of that conversation get 403.
- UNVERIFIED: whether Claude Code's persisted transcripts (`.claude-shared`, resumed by session id) would
  replay such a stale placeholder after rotation or sandbox recreation. If so, rotation could wedge any
  session that ever echoed the env. Mitigations to test: `stable_placeholder: true`, and an agent
  instruction never to print credential env.

## 5. Env vars the agent container must see

Under OpenShell the placeholder env is injected by the supervisor into the sandboxed process tree, not set
by NanoClaw. A new env var reaches only processes launched after the provider update, so a long-lived
container needs a restart to pick up a new key name.

| Path | Var in sandbox | Value | Set by |
|---|---|---|---|
| API key | `ANTHROPIC_API_KEY` | `openshell:resolve:env:v<n>_ANTHROPIC_API_KEY` | OpenShell supervisor |
| OAuth | `CLAUDE_CODE_OAUTH_TOKEN` | `openshell:resolve:env:v<n>_CLAUDE_CODE_OAUTH_TOKEN` | OpenShell supervisor |
| Both | CA trust vars (section 1) | file paths | OpenShell supervisor |
| Both | `ANTHROPIC_BASE_URL` | unset | n/a |

Do not attach both an API key and an OAuth token to one sandbox: `ANTHROPIC_API_KEY` wins in SDK mode and
the OAuth token would be silently unused.

Binary matching (check 1). The profile `binaries` list must match the real, non-symlink path of the
process that opens the socket. The agent-runner starts the CLI as
`pathToClaudeCodeExecutable: '/pnpm/claude'` (`container/agent-runner/src/providers/claude.ts:276`) with
`PNPM_HOME=/pnpm` (`container/Dockerfile`). `/pnpm/claude` is a pnpm shim, so the real target is under
`/pnpm/global/...`. NB lists
`/pnpm/global/*/.pnpm/*/node_modules/@anthropic-ai/claude-code/bin/claude.exe`, `/usr/local/bin/node`,
`/usr/local/bin/bun`. UNVERIFIED: the resolved path in our image for claude-code 2.1.321 (native binary vs
node script). Node and bun entries matter if the runner process itself, not the CLI child, ever calls the
API.

## 6. What NanoClaw sets today

- `src/providers/claude.ts`: host-side container config for the `claude` agent provider. Passes only
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. No credential env, no base URL.
- `src/container-runner.ts` `composeSessionSpec` (~L1414-1470): builds `env` (TZ, mailbox env, HOME) and
  `contributedEnv = { ...contribution.env, ...gateway.env }`. The credential gateway lease is the only
  source of credential-adjacent env, and `gateway.env` overrides `contribution.env`.
- `src/drivers/types.ts` `validateSpec` (~L505-600): in `env`, rejects keys ending `_KEY|_TOKEN|_SECRET|PASSWORD`
  (absolute-path values exempt) and credential-looking values. In `contributedEnv`, rejects only
  credential-looking values (`sk-...`, `gh*_`, `github_pat_`, `xox...`, `AKIA...`, JWT shape, PEM keys).
  `openshell:resolve:env:v1_ANTHROPIC_API_KEY` matches none of these, so a placeholder could pass the
  `contributedEnv` lane if NanoClaw ever needed to set one. It does not need to.
- OneCLI (`.claude/skills/add-onecli/payload/src/gateway-providers/onecli.ts`): `withProviderEnv` adds
  `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN='gateway-managed'` only when a base URL is configured.
  `contributionFromConfig` carries proxy env, CA mounts, `SSL_CERT_FILE`/`DENO_CERT`.
- Agent-runner `container/agent-runner/src/index.ts` (~L121) passes `env: { ...process.env }` to the agent
  provider, and `container/agent-runner/src/providers/claude.ts` forwards `this.env` into the SDK query.
  Whatever env OpenShell injects into the container process reaches the CLI unchanged. No code change is
  needed for pass-through.

Consequence: with OpenShell as the sandbox runtime, the OpenShell provider owns credential delivery and
the NanoClaw credential gateway contribution for Anthropic can be empty. What trunk lacks is the host-side
step that creates the OpenShell provider (profile import, provider create, attach to sandbox) and keeps
`binaries` aligned with the image. Trunk has no OpenShell code. NB's
`src/drivers/openshell/model-provider.ts` is the reference.

## 7. Known breakages and traps

- v0.1.8 placement: `x-api-key` without `auth_style: header` plus `header_name` fails with 403. Re-import
  profiles after editing, upgrade the OpenShell gateway before the supervisor.
- Stale endpoint list in the shipped example (`statsig.anthropic.com`, `sentry.io`). OS says to copy and
  edit rather than import unchanged.
- Binary path mismatch is the likeliest first failure: the proxy denies the connection and the CLI reports
  a generic connection error.
- Placeholder echo (section 4): rotation can wedge sessions that printed the env.
- New provider credentials do not appear in already-running processes. Restart the container.
- Unneeded telemetry hosts are blocked and can add noise unless
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is set.
- OAuth token policy exposure (section 3).

## Open questions (new, for the map)

1. Does claude-code 2.1.321 accept `openshell:resolve:env:v<n>_...` as `ANTHROPIC_API_KEY` and as
   `CLAUDE_CODE_OAUTH_TOKEN` on v0.1.8 with no client-side validation? A live test settles it.
2. What is the resolved real path of the Claude CLI in our image, for the `binaries` list?
3. Do resumed Claude transcripts replay stale placeholders after rotation or sandbox recreation?
4. Should NanoClaw ship the OpenShell provider profile templates itself, and who re-imports them on
   OpenShell gateway upgrades?
5. Is the OAuth path acceptable for this install's user model, given Anthropic's stated restrictions?
