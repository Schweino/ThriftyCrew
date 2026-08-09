# ADR 0006: Funnel telemetry

View, tool-use, signup-click, and join-attempt events go to Workers Analytics Engine with path, release,
product surface, and coarse member tier. No names, email addresses, IP-derived identifiers, or raw visitor
events enter D1. Missing telemetry binding returns an explicit service failure rather than pretending success.
