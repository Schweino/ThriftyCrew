# forbidden-prose-lib.ps1 - THE global health-word sweep over a recipe spec (Brad's ruling, I138).
#
# WHY THIS EXISTS (2026-09-12). `forbidden_prose_terms` is a per-recipe field a writer opts into. It was
# carried by 38 of 584 recipes, so it was a convention and not a rule, and two live paid titles carried the
# word "Healthy" - one of them on a batch that is 5.5% vegetable by weight. Brad's ruling: a title we
# publish on a paid page is our claim whatever blog it came from, no recipe title or reader-facing prose
# may carry a health word unless we own a written bar behind it, the source attribution line stays as it
# is, and "healthy" goes on a GLOBAL list so the Recipe Hunter cannot import the word again.
#
# THE LIST IS DATA, NOT CODE: meal-prep\pipeline\forbidden-prose-global.json. One file, so the readers
# cannot drift apart - this estate has already paid for the notes-vs-bid check being implemented twice.
#
# IT SWEEPS BY DENYLIST, NOT BY ALLOWLIST, and that is the load-bearing choice. An allowlist of
# reader-facing fields leaves a field somebody adds tomorrow silently UNSWEPT, which is the direction that
# fails quietly. So every string in the spec is swept except the ones named in $TC_FORBIDDEN_PROSE_SKIP,
# and each of those is skipped for a reason written beside it.
#
# NO param() BLOCK, DELIBERATELY. A dot-sourced param block runs in the CALLER's scope under PS 5.1 and
# would reset the caller's own -SelfTest switch - the trap guard-contract.ps1's header records. Its
# fixtures live in audit-forbidden-prose.ps1 -SelfTest beside it, which is the detector that owns this rule,
# and in build-v2-spec.ps1 and spec-guards.ps1, which are the two production callers.
#
# Dot-source:  . (Join-Path $here 'forbidden-prose-lib.ps1')

# THE FIELDS THE SWEEP MUST NOT READ. Same shape as dash-sweep.ps1's DASH_SWEEP_SKIP, and the first entry
# is there for exactly the same reason: a ban list that names the banned word is not prose, and a sweep
# that reads it refuses a recipe for carrying the very word it is banning.
#   forbidden_prose_terms  the per-recipe ban list - it NAMES the words on purpose
#   writer_notes, tuning   authoring metadata, never rendered; they quote the rulings they were given
#   credit_html            Brad's ruling: the attribution line naming the originating blog stays as it is
#   source_url, source_site  the same attribution, in machine form
#   slug                   the live URL of a paid page; changing it breaks every link pointing at it
$script:TC_FORBIDDEN_PROSE_SKIP = @(
  'forbidden_prose_terms', 'writer_notes', 'tuning',
  'credit_html', 'source_url', 'source_site', 'slug'
)

# Captured at LOAD time, not inside a function: $MyInvocation inside a function names the function, not
# the file, so a fallback written that way resolves to nothing and the list silently goes missing.
$script:TC_FORBIDDEN_PROSE_DIR = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Get-TcForbiddenProsePath {
  param([string]$Root = '')
  if (-not $Root) { $Root = $script:TC_FORBIDDEN_PROSE_DIR }
  return (Join-Path $Root 'forbidden-prose-global.json')
}

# The global list, as objects carrying term + reason. Reads the JSON every call: it is a 10-entry file and
# a cached copy is one more thing that can be stale inside a long-running lane.
function Get-TcGlobalForbiddenProse {
  param([string]$ListFile = '')
  if (-not $ListFile) { $ListFile = Get-TcForbiddenProsePath }
  if (-not (Test-Path -LiteralPath $ListFile)) {
    throw ("forbidden-prose-lib: the global list is missing: " + $ListFile + " - a sweep with no list is a clean report that proves nothing, so this refuses rather than passing")
  }
  $doc = Get-Content -LiteralPath $ListFile -Raw -Encoding utf8 | ConvertFrom-Json
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($t in @($doc.terms)) {
    if (-not $t -or -not $t.term) { continue }
    $out.Add([pscustomobject]@{ Term = [string]$t.term; Reason = [string]$t.reason })
  }
  if ($out.Count -eq 0) {
    throw ("forbidden-prose-lib: the global list parsed to ZERO terms: " + $ListFile + " - an empty list cannot fire, so this refuses rather than reporting clean")
  }
  return $out.ToArray()
}

# A term matches case-insensitively on WORD BOUNDARIES, and a hyphen and a space are interchangeable
# separators inside it. Substring matching was rejected: "healthy" would then fire inside the attribution
# host healthyfoodiegirl.com, and the estate's own rule is that a clean report must mean something.
function Get-TcForbiddenProsePattern {
  param([string]$Term)
  $parts = @($Term -split '[- ]+' | Where-Object { $_ })
  if ($parts.Count -eq 0) { throw 'forbidden-prose-lib: empty term' }
  $body = ($parts | ForEach-Object { [regex]::Escape($_) }) -join '[- ]'
  return ('(?i)\b' + $body + '\b')
}

# Every (field path, string) pair a reader can get out of this spec. Walks the whole object so a field
# added tomorrow is swept by default; see the skip list above for the six that are not.
function Get-TcReaderProseString {
  param($Spec)
  $out = New-Object System.Collections.Generic.List[object]
  $q = New-Object System.Collections.Generic.Queue[object]
  $q.Enqueue([pscustomobject]@{ Path = ''; Value = $Spec })
  while ($q.Count -gt 0) {
    $node = $q.Dequeue()
    $v = $node.Value
    if ($null -eq $v) { continue }
    if ($v -is [string]) { $out.Add([pscustomobject]@{ Field = $node.Path; Text = $v }); continue }
    if ($v -is [System.Collections.IDictionary]) {
      foreach ($k in @($v.Keys)) {
        if ($script:TC_FORBIDDEN_PROSE_SKIP -contains [string]$k) { continue }
        $p = if ($node.Path) { $node.Path + '.' + [string]$k } else { [string]$k }
        $q.Enqueue([pscustomobject]@{ Path = $p; Value = $v[$k] })
      }
      continue
    }
    if ($v -is [System.Collections.IEnumerable]) {
      $i = 0
      foreach ($vv in $v) { $q.Enqueue([pscustomobject]@{ Path = ($node.Path + '[' + $i + ']'); Value = $vv }); $i++ }
      continue
    }
    if ($v -is [psobject] -and $v.PSObject.Properties.Count -gt 0) {
      foreach ($p in $v.PSObject.Properties) {
        if ($script:TC_FORBIDDEN_PROSE_SKIP -contains [string]$p.Name) { continue }
        $path = if ($node.Path) { $node.Path + '.' + [string]$p.Name } else { [string]$p.Name }
        $q.Enqueue([pscustomobject]@{ Path = $path; Value = $p.Value })
      }
    }
  }
  return $out.ToArray()
}

# The findings for one spec: term, the field it sits in, and enough of the string to act on.
function Get-TcForbiddenProseHit {
  param($Spec, $Terms = $null)
  if ($null -eq $Terms) { $Terms = Get-TcGlobalForbiddenProse }
  $strings = Get-TcReaderProseString $Spec
  $hits = New-Object System.Collections.Generic.List[object]
  foreach ($t in @($Terms)) {
    $rx = Get-TcForbiddenProsePattern $t.Term
    foreach ($s in $strings) {
      $m = [regex]::Match($s.Text, $rx)
      if (-not $m.Success) { continue }
      $start = [Math]::Max(0, $m.Index - 30)
      $len = [Math]::Min(100, $s.Text.Length - $start)
      $hits.Add([pscustomobject]@{
        Term    = $t.Term
        Field   = $s.Field
        Matched = $m.Value
        Excerpt = $s.Text.Substring($start, $len)
      })
    }
  }
  return $hits.ToArray()
}

# One line per finding, in the form every caller prints it.
function Format-TcForbiddenProseHit {
  param($Hit, [string]$Slug = '')
  $who = if ($Slug) { $Slug + ': ' } else { '' }
  return ($who + "forbidden prose term '" + $Hit.Term + "' in " + $Hit.Field + " - ..." + $Hit.Excerpt + "...")
}
