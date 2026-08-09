# ADR 0001: Authority boundaries

Git owns code, migrations, fixtures, recipes, and authored configuration. D1 owns operational state. R2 owns
evidence and large immutable payloads. Analytics Engine owns non-PII funnel events. Ghost owns content,
memberships, billing, newsletters, and live paywall truth. Only the Worker mutates Cloudflare state.
