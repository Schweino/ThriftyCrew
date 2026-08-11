# ADR 0004: Mutation security

PC capture and registered PC agents use separate scoped HMAC credentials with timestamp and nonce replay
protection; local secrets are DPAPI-protected for the scheduled-task user. The Worker binds agent credentials
to active PC registry entries and enforces their declared capabilities. Manual GitHub fallback uses signed OIDC
bound to issuer, audience, repository, caller and reusable workflow. Every private endpoint applies a role gate
and audit identity; there is no direct D1 writer.
