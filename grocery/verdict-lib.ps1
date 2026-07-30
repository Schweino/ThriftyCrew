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
