# NanoClaw (artebot)

A personal AI assistant host that runs each conversation session in an isolated sandbox and brokers its credentials. This glossary pins the words used when talking about where sessions run and how they reach the outside world.

## Isolation and credentials

**Session driver**:
NanoClaw's seam that turns a session spec into a running sandbox and supervises it (`docker`, `openshell`).
_Avoid_: runtime, backend, isolation backend

**Credential gateway**:
NanoClaw's seam that injects secrets into a session's outbound requests at the network boundary and holds requests for human approval (OneCLI, Iron Proxy, OpenShell).
_Avoid_: gateway (unqualified), proxy, vault

**OpenShell**:
NVIDIA's sandbox runtime for agents; in this project it fills both the session driver and the credential gateway roles.
_Avoid_: OpenShell runtime (ambiguous with compute driver)

**OpenShell gateway**:
OpenShell's own long-running control-plane service that creates sandboxes and enforces their policy. Always qualified with "OpenShell" to keep it apart from the credential gateway.
_Avoid_: gateway (unqualified)

**Compute driver**:
The layer underneath OpenShell that actually runs a sandbox (Docker, Podman, MicroVM, Kubernetes). Never NanoClaw's concern directly.
_Avoid_: session driver, runtime

**OpenShell provider**:
A named credential registered with the OpenShell gateway and attached to a sandbox; the sandbox sees only a placeholder.
_Avoid_: provider (unqualified — collides with NanoClaw's agent provider, e.g. Claude or Codex)
