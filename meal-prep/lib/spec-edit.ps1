# spec-edit.ps1 - THE one way to edit a text field inside a recipe spec's raw JSON.
#
# WHY THIS EXISTS (2026-08-08 architecture review). A spec file cannot be parse-and-reserialized: the prose
# carries \uXXXX escapes and ConvertTo-Json would rewrite every one of them, so every editor works on the
# RAW text. Nine pipeline scripts had each reimplemented that surgery privately, and the private copies are
# where the estate's worst self-inflicted bugs came from:
#   * the 2026-08-07 prose disaster: a regex ran over the ENCODED text, where > puts a letter 'e' in
#     front of a number, killing \b and satisfying (?<![a-z]) - 11 specs got "under 400 calories" rewritten
#     to "under 357 calories" before the diff was read;
#   * '$1' + $grams produced "$136.850" because .NET read $13 as capture group 13, corrupting JSON;
#   * a round-trip check that compared a decode TO ITSELF - a tautology that would have passed anything.
# Every function here works decode -> edit -> re-encode, never regex-over-encoded-text, and every write is
# verified three ways before it lands: the result parses, the re-encode round-trips losslessly, and every
# field NOT named in the edit is byte-identical.
#
# Dot-source:  . (Join-Path $mp 'lib\spec-edit.ps1')
# Self-test:   powershell -File lib\spec-edit.ps1 -SelfTest
param([switch]$SelfTest)

# Encode a plain string exactly the way the estate's spec files store strings (ConvertTo-Json escaping,
# which is what wrote the files originally - so < stays < and the file's style is preserved).
function ConvertTo-SpecEncoded { param([string]$Text)
  $j = ConvertTo-Json $Text -Compress
  return $j.Substring(1, $j.Length - 2)
}
function ConvertFrom-SpecEncoded { param([string]$Encoded)
  return ($('"' + $Encoded + '"') | ConvertFrom-Json)
}

# Locate a string field's VALUE in the raw text. $Key is the bare key name; it must appear exactly once in
# the file (multi-occurrence keys like "description" inside head are fine as long as the whole file holds
# one - the caller's spec shape guarantees that, and this throws rather than guessing when it does not).
function Get-SpecFieldRaw { param([string]$Raw, [string]$Key)
  $rx = '("' + [regex]::Escape($Key) + '"\s*:\s*")((?:[^"\\]|\\.)*)(")'
  $m = [regex]::Matches($Raw, $rx)
  if ($m.Count -ne 1) { throw ("spec-edit: key '{0}' appears {1} time(s) as a string field - need exactly 1 to edit safely" -f $Key, $m.Count) }
  return [pscustomobject]@{
    Key        = $Key
    ValueIndex = $m[0].Groups[2].Index
    ValueLen   = $m[0].Groups[2].Length
    Encoded    = $m[0].Groups[2].Value
    Decoded    = (ConvertFrom-SpecEncoded $m[0].Groups[2].Value)
  }
}

# Replace one string field's value in the raw text, returning the new raw. Pure - no file IO. The caller
# passes PLAIN text; encoding happens here, with a lossless round-trip proof before anything is returned.
function Set-SpecFieldInRaw { param([string]$Raw, [string]$Key, [string]$NewText)
  $f = Get-SpecFieldRaw -Raw $Raw -Key $Key
  $enc = ConvertTo-SpecEncoded $NewText
  $verify = ConvertFrom-SpecEncoded $enc
  if ($verify -ne $NewText) { throw ("spec-edit: encoding of '{0}' does not round-trip losslessly - refusing" -f $Key) }
  return $Raw.Substring(0, $f.ValueIndex) + $enc + $Raw.Substring($f.ValueIndex + $f.ValueLen)
}

# Compare two parsed specs and throw if anything OTHER than the allowed keys moved. Allowed keys are
# top-level names, or 'head.<sub>' for fields inside head.
function Assert-SpecCollateral { param($Before, $After, [string[]]$AllowedKeys)
  $allowTop  = @($AllowedKeys | Where-Object { $_ -notmatch '^head\.' })
  $allowHead = @($AllowedKeys | Where-Object { $_ -match '^head\.' } | ForEach-Object { $_ -replace '^head\.', '' })
  foreach ($p in $Before.PSObject.Properties) {
    if ($allowTop -contains $p.Name) { continue }
    if ($p.Name -eq 'head' -and $allowHead.Count) {
      foreach ($hp in $Before.head.PSObject.Properties) {
        if ($allowHead -contains $hp.Name) { continue }
        $b = ($Before.head.$($hp.Name) | ConvertTo-Json -Depth 14 -Compress)
        $a = ($After.head.$($hp.Name)  | ConvertTo-Json -Depth 14 -Compress)
        if ($b -ne $a) { throw ("spec-edit: collateral change in head.{0} - aborted" -f $hp.Name) }
      }
      continue
    }
    $b = ($p.Value | ConvertTo-Json -Depth 14 -Compress)
    $a = ($After.$($p.Name) | ConvertTo-Json -Depth 14 -Compress)
    if ($b -ne $a) { throw ("spec-edit: collateral change in '{0}' - aborted" -f $p.Name) }
  }
}

# The full write: edit one or more string fields in a spec FILE with every verification this library owns.
# $Edits is a hashtable of key -> new plain text ('description' edits head.description in every spec shape
# this estate uses, because that is the file's only string field by that name).
function Set-SpecFields { param([string]$Path, [hashtable]$Edits)
  $raw = [IO.File]::ReadAllText($Path)
  $before = $raw | ConvertFrom-Json
  $new = $raw
  foreach ($k in $Edits.Keys) { $new = Set-SpecFieldInRaw -Raw $new -Key $k -NewText ([string]$Edits[$k]) }
  $after = $null
  try { $after = $new | ConvertFrom-Json } catch { throw ("spec-edit: result for {0} would not parse - aborted" -f (Split-Path $Path -Leaf)) }
  $allowed = @($Edits.Keys | ForEach-Object { if ($_ -eq 'description') { 'head.description' } else { $_ } })
  Assert-SpecCollateral -Before $before -After $after -AllowedKeys $allowed
  [IO.File]::WriteAllText($Path, $new)
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  # FROZEN FIXTURE: the prose disaster's raw shape - encoded text where < is <. An edit through this
  # library decodes first, so the 'e' of > can never sit next to a number during matching.
  $raw = '{ "stat": { "cal": 460 }, "portion_html": "Lands <strong>under 400 calories</strong> a bowl.", "head": { "description": "A soup.", "costPerServing": 5.76 } }'
  $g1 = Get-SpecFieldRaw -Raw $raw -Key 'portion_html'
  T 'decode gives PLAIN text (the < is a real <, not <)' ($g1.Decoded -eq 'Lands <strong>under 400 calories</strong> a bowl.') $g1.Decoded

  $new = Set-SpecFieldInRaw -Raw $raw -Key 'portion_html' -NewText 'Lands <strong>near 460 calories</strong> a bowl.'
  $parsed = $new | ConvertFrom-Json
  T 'edit re-encodes in the file''s own style and parses' ($parsed.portion_html -eq 'Lands <strong>near 460 calories</strong> a bowl.') $parsed.portion_html
  T 'the escapes are preserved in raw form (< stays <)' ($new -match '\\u003cstrong\\u003e') 'escapes rewritten'

  # MUST FIRE: a duplicate key refuses rather than guessing which one to edit.
  $dup = '{ "a": "x", "portion_html": "one", "nested": { "portion_html": "two" } }'
  $threw = $false; try { Get-SpecFieldRaw -Raw $dup -Key 'portion_html' | Out-Null } catch { $threw = $true }
  T 'MUST FIRE  a key appearing twice is refused, never guessed' $threw 'edited one of two silently'

  # MUST FIRE: collateral detection - an edit that somehow moved another field aborts.
  $b = '{"x":"1","y":"2"}' | ConvertFrom-Json
  $a = '{"x":"1","y":"CHANGED"}' | ConvertFrom-Json
  $threw2 = $false; try { Assert-SpecCollateral -Before $b -After $a -AllowedKeys @('x') } catch { $threw2 = $true }
  T 'MUST FIRE  collateral change in an unnamed field aborts the write' $threw2 'silent collateral'

  # CLEAN TWIN: head.<sub> scoping - editing head.description leaves head.costPerServing checked and intact.
  $b2 = '{"head":{"description":"old","costPerServing":5.76}}' | ConvertFrom-Json
  $a2 = '{"head":{"description":"new","costPerServing":5.76}}' | ConvertFrom-Json
  $ok = $true; try { Assert-SpecCollateral -Before $b2 -After $a2 -AllowedKeys @('head.description') } catch { $ok = $false }
  T 'CLEAN TWIN head.description may move while the rest of head is enforced' $ok 'false collateral'
  $a3 = '{"head":{"description":"new","costPerServing":9.99}}' | ConvertFrom-Json
  $threw3 = $false; try { Assert-SpecCollateral -Before $b2 -After $a3 -AllowedKeys @('head.description') } catch { $threw3 = $true }
  T 'MUST FIRE  a head sibling moving alongside is still caught' $threw3 'head collateral missed'

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}
