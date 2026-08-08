<#
copy-rules.ps1 - standing rules about what the videos may say, enforced rather than remembered.

WHY THIS IS CODE AND NOT A NOTE
  The daily reel runs unattended from a scheduled task with no human and no model in the loop. A
  rule that lives in someone's memory, or in a README, or in an assistant's notes, is a rule that
  holds only while somebody happens to recall it. A rule that fails the build holds forever.

  It also runs BEFORE synthesis and rendering, so a violation costs a second rather than a finished
  video nobody notices is wrong until it is on the Page.

SCOPE
  Video copy only: spoken narration, on-screen cards, captions and the post text. The site, the
  grocery board and the recipe pages are deliberately NOT covered, because there the specificity is
  the thing that earns trust.
#>

# Term -> why it is banned. The reason travels with the rule so whoever trips it can judge whether
# the rule still applies, rather than just deleting the check.
$script:TcBannedCopy = [ordered]@{
  'Omaha' = @'
Brad, 2026-08-08: videos say "real stores" or "store prices", never the city. The prices ARE Omaha's,
but naming it tells everyone outside Omaha the page is not for them, and the goal is enough traffic
that requests to expand become the signal for where to go next. This is still honest: they are real
stores, every figure traces to the same seven-store board, and the week is stamped on the frame.
Applies to narration, cards, captions, post text and hashtags. NOT to the site or the board.
'@
}

function Assert-CopyRules {
  <# Fail the build on any banned term in user-facing copy.

     Pass every string a viewer could see or hear. Cheap enough to call on all of them, and the
     point is that no surface is exempt: the rule was broken in twelve places across two builders
     the first time, spread over narration, an eyebrow, a stamp, fine print, a caption and a
     hashtag. Checking only the obvious one would have missed most of them. #>
  # AllowEmptyString/AllowEmptyCollection are load-bearing, not tidiness: callers pass whole sets of
  # fields at once and plenty are legitimately blank (a card with no eyebrow, a scene with no sub).
  # Without these, Mandatory rejects the blank and the guard takes the build down on valid copy,
  # which is how a safety check earns itself a deletion.
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()]
    [string[]] $Text,
    [string] $Context = 'video copy'
  )
  foreach ($t in $Text) {
    if ([string]::IsNullOrWhiteSpace($t)) { continue }
    foreach ($term in $script:TcBannedCopy.Keys) {
      # Word-boundary match, so it catches "#omaha" and "Omaha's" without firing on a substring
      # inside some unrelated word.
      if ($t -match "(?i)\b$([regex]::Escape($term))\b") {
        throw ("BANNED TERM '$term' in $Context.`n" +
               "  ...$(($t -replace '\s+', ' ').Trim())`n`n" +
               $script:TcBannedCopy[$term])
      }
    }
  }
}
