# Funnel telemetry privacy and retention

The application records only four product events: `view`, `tool_use`, `signup_click`, and `join_attempt`.
Dimensions are URL path, coarse member tier (`anonymous`, `free`, `paid`, `unknown`), release ID, and a bounded
product/surface label. The event contract rejects arbitrary event names and does not accept name, email,
membership ID, cookie value, IP address, free-form text, or a persistent visitor identifier.

Raw events exist only in the `tc_grocery_funnel` Workers Analytics Engine dataset and follow Cloudflare's
three-month dataset retention. They are never copied into operational D1. Monthly aggregate funnel counts may
be exported for long-range business comparison; aggregates must contain at least 20 events per cohort and no
new visitor-level dimensions. Removing the Analytics Engine binding makes the endpoint return 503, not a false
success.
