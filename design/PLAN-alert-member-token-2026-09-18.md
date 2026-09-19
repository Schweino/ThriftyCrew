# PLAN: price alerts trust the member's own sign-in, not a typed email

Status: DRAFT for Brad, 2026-09-18. Nothing deploys until he approves. Backlog: the code-review item
"the price-alert endpoint tells a stranger which emails belong to paying members".

## The defect, verified in code

`worker/index.js`, `/alert`: the board posts `{email, item, weekly}`; the Worker looks the typed email up
with the Ghost Admin key and answers **200** for a paid or comped member, **403 "members-only perk"** for
anyone else. Two harms:

1. **Membership lookup for strangers.** Post a list of emails, read which get 200: that list is who pays.
2. **Signing up someone else.** Type a paying member's email and their inbox gets alerts they never asked for.

The route's own comment says the board's client check is UX, not security, and that is right; the server
check is the security, and it checks an identity the caller chose.

## The fix

The board is a Ghost page on thriftycrew.com, where a signed-in member has a session cookie. Ghost gives
that member a short-lived **signed identity token** (`GET /members/api/session`, same origin, returns a JWT
whose subject is the member's email), and publishes the public keys to check it
(`/members/.well-known/jwks.json`).

- **Board:** when the alert button is pressed, fetch the token from `/members/api/session`. No token (not
  signed in) shows the existing "members-only perk, join for $1/month" message without calling the Worker.
  With one, post `{item, weekly}` with the token in an `Authorization` header. The email box goes away for
  signed-in members, which also removes a typing step.
- **Worker:** verify the token's signature against Ghost's published keys (cached), its expiry and its
  issuer; take the email from the token, never from the body; then the existing paid-or-comped check.
  **Every refusal before that check gets one identical answer**, so a response never says whether an email
  is a member.

## Rung 1, before any build (read only)

- Confirm on the live site that `/members/api/session` returns a token for a signed-in member and what its
  claims and algorithm are; confirm the keys URL. (Stated from Ghost's documented member API, not yet
  checked against this site.)
- Count how many alert signups exist and how many came from non-members, from the `alert-<id>` labels, so
  we know whether the leak was ever used (it cannot be proven either way, only bounded).

## Rollout and reversibility

Worker change first, **accepting both shapes for one day**: a token if present, else the old path, so a
cached old board keeps working. Then the board rebuild, then drop the old path. Each step is a redeploy,
so each is reversible. Verified by: a signed-in paid member signs up; a signed-out visitor gets the
join message; a posted email with no token gets the generic refusal, identical for a member's email and
a stranger's (the enumeration case, as a MUST FIRE); the 375px check on the board.

## Knowledge consulted

- `security-craft/estate-exposure.md` sections 1 and 4: the estate is in the threat model, and the layer
  that matters is the server-side check. Here that check exists but reads the wrong identity.
- memory `paywall-leak-direction-unwatched`: check the direction that loses money or data, not the
  cosmetic one; the client-side gate was the cosmetic direction.
- `.claude/rules/site-and-publish.md`: live paid site, the 375px check, and a measurement is not a look.
- Searched "enumeration", "rate limit", "timing": nothing on web-auth token verification in the store;
  this plan is the first, and the verified result should go back into security-craft.

## Decision for Brad

Approve the design, then I build it on a branch, verify against the live site in the browser, and ask
again before the Worker deploy and the board publish.
