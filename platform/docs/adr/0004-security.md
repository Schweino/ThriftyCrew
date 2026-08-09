# ADR 0004: Mutation security

PC capture uses scoped rotating HMAC credentials with timestamp and nonce replay protection. GitHub Actions
uses a signed OIDC token bound to issuer, custom audience, repository, and workflow plus per-request timestamp
and nonce. Every private endpoint applies a role gate and an audit identity; there is no direct D1 writer.
