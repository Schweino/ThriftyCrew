<#
  verdict-lib.ps1 - the ONE definition of how a verdict identifies the product it judged.

  Shared by verify-apply.ps1 (applies + records suppressions) and audit-match-soundness.ps1 (the -Accept
  verdict gate). Both must agree on what "the same item" means, or a product suppressed by one is invisible
  to the other - and two copies of one rule is how the pu-lib "1/2 gal" and Get-SizeAmount divergences
  happened. Anything that keys a verdict to a product name goes through these two functions.

  *** NO param() BLOCK, DELIBERATELY *** - dot-sourcing runs a script's param() in the CALLER's scope
  (capture-lib.ps1 learned this the hard way on 2026-07-29).
  *** PURE ASCII *** - the quote characters are built from code points, because a file that reasons about
  text encoding must survive being read under the wrong codepage itself.
#>

function Get-VerdictNorm([string]$s) {
  <#
    Normalised product identity: lowercase, alphanumerics only, single-spaced.
    The feed and a verdict's reason spell the same product differently ("Pinto Beans, 12 lbs." vs
    "Pinto Beans 12 lbs."), so raw-string equality misses exactly the rows that matter.
  #>
  if ([string]::IsNullOrEmpty($s)) { return '' }
  return (($s.ToLower() -replace '[^a-z0-9]+', ' ').Trim())
}

function Get-VerdictQuotePattern {
  <#
    Captures the product name quoted inside a verdict's reason text.
    THE DETAIL THAT DECIDES WHETHER THIS WORKS AT ALL: the closing quote is only a closing quote when
    followed by space/punctuation/end. Product names carry apostrophes ("Member's Mark ..."), and a naive
    [^']+ capture truncates at the possessive - failing SILENT, because the truncated name matches nothing
    and the verdict is simply skipped. Straight and curly quote forms both handled.
  #>
  $q1 = [char]0x0027; $q2 = [char]0x2018; $q3 = [char]0x2019; $q4 = [char]0x201C; $q5 = [char]0x201D
  return "[$q1$q2$q4](.{6,}?)[$q1$q3$q5](?=\s|$|[,.;:!?)\]])"
}

function Get-VerdictQuotedItem([string]$reason) {
  # The judged item recovered from a reason, or '' when the reason describes without quoting -
  # in which case the caller must NOT guess: an unverifiable identity is skipped, never inferred.
  if ([string]::IsNullOrEmpty($reason)) { return '' }
  $m = [regex]::Match($reason, (Get-VerdictQuotePattern))
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-VerdictIdentity($entry) {
  <#
    THE judged item of a verdict entry, best evidence first: the entry's own 'item' field, else the name
    quoted in its reason, else '' (and '' means SKIP - an unverifiable identity is never guessed at).

    WHY THIS IS HERE AND NOT INLINE (2026-08-16, queue 2026-08-07-79b768): verdict files gained a structured
    'item' field on 2026-08-05. The item-first refinement was then written inline in verify-apply.ps1 and
    purge-verdict-lows.ps1 and never hoisted, so the -Accept gate kept identifying its subject by re-parsing
    rendered prose - and its founding premise ("a verdict names the commodity and store but NOT the item")
    had silently stopped being true. It cut both ways:
      * FALSE BLOCK - the 2026-08-15 garlic verdict judged 'Marketside Tandoori Style Garlic Naan Bites,
        7.05 oz, 15 Count' but its reason quotes the flavour word 'Garlic', so the gate keyed garlic|garlic,
        resolved that to Aldi's real Garlic ($1.69 / 3 ct = $0.5633/each) and refused -Accept naming an
        innocent product, under the wrong store. Same shape sat live on bacon and parmesan.
      * SILENT UNDER-BLOCK - a quote that captures a SIZE ('169 FL OZ') or a reordered name ('red butter
        lettuce' vs the feed's 'Lettuce Red Butter') matches no feed name, so a reviewed DROP was never
        enforced and nobody could see it.
    A shared-lib fix ships nothing while callers keep their own copy, so all three consumers call THIS.
  #>
  if ($null -eq $entry) { return '' }
  if ($entry.PSObject.Properties['item'] -and $entry.item) { return [string]$entry.item }
  return (Get-VerdictQuotedItem ([string]$entry.reason))
}
