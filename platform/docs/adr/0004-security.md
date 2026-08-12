# ADR 0004: Mutation security

PC capture and registered PC agents use separate scoped HMAC credentials with timestamp and nonce replay
protection; local secrets are DPAPI-protected for the scheduled-task user. The Worker binds agent credentials
to active PC registry entries and enforces their declared capabilities. Manual GitHub fallback uses signed OIDC
bound to issuer, audience, repository, caller and reusable workflow. Every private endpoint applies a role gate
and audit identity; there is no direct D1 writer.

The internet-facing `tc-grocery-public` Worker has no D1, R2, workflow, Ghost, mutation-key, or alert-secret
bindings. It validates the accepted host and forwards through a Cloudflare service binding. The privileged
`tc-grocery-v3` control Worker has no route and no `workers.dev` endpoint; all ingress crosses the public
gateway and then the service binding. The local capture controller exposes only an authenticated Windows named
pipe and its token-bearing configuration file is ACL-restricted to the current user and SYSTEM.
