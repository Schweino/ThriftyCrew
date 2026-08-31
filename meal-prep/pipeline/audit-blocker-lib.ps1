# audit-blocker-lib.ps1
# ---------------------------------------------------------------------------------------------------
# ONE reader for the blocker headings in a wave audit report, shared by the command that ACTS on them
# (hunt-run.ps1 -Revive) and the gate that keeps them readable (audit-wave-blocker-headings.ps1).
#
# WHY THIS IS A LIBRARY AND NOT TWO COPIES (2026-08-29). -Revive decides whether a rejected recipe was
# rejected for somebody else's defect, and it decides it by reading the audit's own blocker headings.
# For as long as that command existed it read for `### BLOCKER n (kind)` - a form NO auditor has ever
# written. Every real report says `### Blocker 1 (recipe-local): ...`, `### R1. ... (recipe-local,
# pipeline)`, `### B1. ... (shared, pipeline + shared-data)` or `### 1. ... (recipe-local)`, so the
# matcher found nothing in any of them and -Revive refused all eleven live rejections with "names no
# open blockers" - wording that reads as "this rejection is sound" but means "I cannot parse the file".
# Eleven finished recipes sat terminal on it.
#
# A gate that checks the headings is only worth anything if it checks the SAME string the command
# reads. Two implementations of "what is a blocker heading" is how the gate goes green while the
# command still sees nothing, which is precisely the failure this file exists to end. So: one reader,
# both callers, and the gate's guarantee is therefore a guarantee about -Revive's input.
# ---------------------------------------------------------------------------------------------------

# The kind vocabulary. A heading must declare one of these for anyone to tell WHOSE defect it was.
# `shared-data` contains `shared`, so a single tag can score both - harmless, because the only kind
# that changes a verdict is `recipe-local` and the rest exist to prove a kind was declared at all.
$script:BLOCKER_KINDS = @('recipe-local', 'shared-data', 'shared', 'process', 'orchestration')

function Test-IsBlockerHeading {
  <#
    Does this line open a blocker section?

    The label must LEAD, immediately after the hashes, and that single rule is ALSO what excludes
    `### Prior BLOCKER 3` - a blocker an earlier cycle already CLOSED - because `Prior` is not one of
    the labels. Holding a recipe terminal for a defect that is on record as fixed is the bug this
    whole path exists to undo, so that exclusion matters; it just does not need its own check.

    There WAS a separate `^###\s+Prior\s` guard here. Neutering it left every case green, because the
    leading anchor had already done the work - dead code that read like a second safeguard. Deleted
    rather than kept as belt-and-braces: a check that cannot fail teaches the next reader that
    something is defended when only one thing actually defends it.

    `\d*` is optional: `### Blocker (shared-data, NOT recipe-local)` carries no number. The trailing
    `\s` is NOT optional: it is the only thing stopping the bare `B` alternative from swallowing
    `### Battery failure re-derived CLEAN`, which is explicitly not a blocker.
  #>
  param([string]$Line)
  $s = [string]$Line
  # ## AS WELL AS ### (2026-08-31). The matcher required exactly three hashes, and THREE real NO-GO
  # reports on disk write their blockers at ## - hunt-2026-08-27-ten waves 2 and 3 use
  # `## BLOCKER 1 - <slug> (recipe-local)`. Not one of their blockers was visible, so those reports
  # parsed to ZERO blockers, which -Revive and -Repair both read as "this rejection names no open
  # blocker" and refused. Four finished recipes sat terminal on a hash count. It is the same failure
  # this file's own header describes - a matcher that reads a form no auditor has ever written - just
  # one level up, and the gate that is supposed to police these headings was equally blind to whole
  # reports, so nothing said the reports were unreadable either.
  # AND THE TWO LEVELS TAKE DIFFERENT LABELS, which is not tidiness. At ### the abbreviated forms are
  # safe because ### is only ever used for a blocker in these reports. At ## they are NOT: a GO report
  # in hunt-2026-08-15-shakedown carries `## B5 VERIFICATION - FIXED, both parts`, a note recording a
  # blocker that was CLOSED, and the first cut of this widening read it as an open one - inventing a
  # kindless blocker in a report that had none and taking the headings gate red over it. So ## demands
  # the word BLOCKER spelled out, which is what every real ##-level blocker on disk actually writes.
  if ($s -match '^###\s') {
    if ([regex]::IsMatch($s, '^###\s+(?:BLOCKER|Blocker|B|R)\s*\d*\s*[.:\-]?\s')) { return $true }
    return [regex]::IsMatch($s, '^###\s+\d+\.\s')
  }
  if ($s -match '^##\s') {
    return [regex]::IsMatch($s, '^##\s+(?:BLOCKER|Blocker)\s*\d*\s*[.:\-]?\s')
  }
  return $false
}

function Get-BlockerKindsFromLine {
  <#
    The kinds declared anywhere in this heading's parentheses. Half the reports tag the kind right
    after the label and half put it at the end, so every parenthesised group is read, not just the
    first.

    A deliberate imprecision lives here: a heading reading `(shared-data, NOT recipe-local)` scores
    recipe-local, which makes -Revive REFUSE. That errs toward leaving a rejection standing, and for
    the one command that undoes a verdict that is the safe direction to be wrong in.
  #>
  param([string]$Line)
  $out = @()
  foreach ($grp in [regex]::Matches([string]$Line, '\(([^)]*)\)')) {
    $inner = $grp.Groups[1].Value
    foreach ($k in $script:BLOCKER_KINDS) {
      if ($inner -match [regex]::Escape($k)) { $out += $k }
    }
  }
  return @($out)
}

function Get-LeadingKindDeclaration {
  <#
    The kind stated as the OPENING TOKEN of a blocker's body line, e.g. `Recipe-local. Owner: mapper.`

    THE HEADING IS NOT THE ONLY PLACE AUDITORS PUT IT, and reading only the heading nearly cost two
    more recipes (2026-08-29). Wave 5 of hunt-2026-08-27-highprotein writes:
        ### Blocker 1 - healthy-hamburger-helper: macros computed on Protein+ pasta...
        Recipe-local. Owner: recipe-ingredient-mapper.
    The auditor DID classify both blockers, on the line underneath. A reader that only looked at the
    heading called that "no kind declared" and refused -Repair on a recipe whose defect the report
    names in the clearest possible terms.

    Deliberately strict: the kind must be the line's LEADING token, optionally followed by punctuation.
    Scanning body prose for the word `shared` would classify "this is a shared concern" as a kind and
    quietly turn a recipe-local blocker into a revivable one, which is the dangerous direction.
  #>
  param([string]$Line)
  $s = ([string]$Line).TrimStart()
  foreach ($k in $script:BLOCKER_KINDS) {
    if ([regex]::IsMatch($s, '^' + [regex]::Escape($k) + '\b', 'IgnoreCase')) { return @($k) }
  }
  return @()
}

function Test-IsBlockingSectionHeader {
  <#
    `## BLOCKING issues (both recipe-local, both in writer-authored spec strings)`

    THE OLDEST FORM ON DISK (hunt-2026-08-24-v3-phase6b wave 2). Its blockers are bare `B1.` / `B2.`
    label lines with no hashes at all, and the kind is declared ONCE for the section rather than on
    each blocker. The auditor did classify them - in the clearest possible terms, in its own words -
    and a reader that demanded a per-blocker tag called that "no kind declared" and left
    creamy-roasted-garlic-chicken with no way back, both of its defects having been repaired.

    DELIBERATELY NARROW. The header must BEGIN with the word BLOCKING, which is what keeps
    `## Non-blocking findings (recorded)` out - that section's parenthesis would otherwise hand a
    kind to findings the auditor explicitly said do not block, and inheriting a kind into the
    non-blocking section is the one direction that could revive a recipe nobody cleared.
  #>
  param([string]$Line)
  return [regex]::IsMatch(([string]$Line), '^#{1,4}\s+BLOCKING\b', 'IgnoreCase')
}

function Test-IsBareBlockerLabel {
  <# `B1. MILK BULLET CONTRADICTS...` - a blocker label with no hashes, only legal INSIDE a
     BLOCKING-issues section. Requiring the number and the punctuation is what stops an ordinary
     sentence starting with "B" or "R" from being read as a blocker. #>
  param([string]$Line)
  return [regex]::IsMatch(([string]$Line), '^(?:BLOCKER|Blocker|B|R)\s*\d+\s*[.:\-]\s')
}

function Get-BlockerKinds {
  <#
    Every OPEN blocker in one report, as the kinds it declares - in its heading's parentheses, or as
    the leading token of the body line(s) directly beneath it, whichever the auditor used.

    Only the lines up to the next heading are read, so one blocker's classification can never be
    credited to the blocker after it.
  #>
  param([string]$Path)
  $lines = @(Get-Content $Path)
  $out = @()
  $sectionKinds = @()      # kinds declared by the enclosing `## BLOCKING issues (...)` header
  $inBlocking = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ([string]$lines[$i] -match '^#{1,4}\s') {
      if (Test-IsBlockingSectionHeader $lines[$i]) {
        $inBlocking = $true
        $sectionKinds = @(Get-BlockerKindsFromLine $lines[$i])
      } elseif (-not (Test-IsBlockerHeading $lines[$i])) {
        # any OTHER heading closes the section, so `## Non-blocking findings` cannot inherit
        $inBlocking = $false
        $sectionKinds = @()
      }
    }
    $isHeading = Test-IsBlockerHeading $lines[$i]
    $isBare = $inBlocking -and (Test-IsBareBlockerLabel $lines[$i])
    if (-not $isHeading -and -not $isBare) { continue }
    $kinds = @(Get-BlockerKindsFromLine $lines[$i])
    if (-not $kinds.Count -and $isBare) { $kinds = @($sectionKinds) }
    if (-not $kinds.Count) {
      # Look only at the body of THIS blocker, and only until it says something that is not a
      # classification - two lines is the whole convention in every report on disk.
      for ($j = $i + 1; $j -lt $lines.Count -and $j -le $i + 2; $j++) {
        if ([string]$lines[$j] -match '^###\s') { break }
        $k = @(Get-LeadingKindDeclaration $lines[$j])
        if ($k.Count) { $kinds = $k; break }
      }
    }
    $out += [pscustomobject]@{ heading = ([string]$lines[$i]).TrimEnd(); kinds = @($kinds) }
  }
  return @($out)
}

function Get-AuditBlockerKinds {
  <# Every kind declared by every OPEN blocker in one audit report, flattened. #>
  param([string]$Path)
  $kinds = @()
  foreach ($b in @(Get-BlockerKinds $Path)) { $kinds += @($b.kinds) }
  return @($kinds)
}

function Get-KindlessBlockerHeadings {
  <# The blockers that never say whose defect they were, in the heading or beneath it. #>
  param([string]$Path)
  $bad = @()
  foreach ($b in @(Get-BlockerKinds $Path)) {
    if (@($b.kinds).Count) { continue }
    $bad += $b.heading
  }
  return @($bad)
}
