# audit-board-mojibake.ps1 - does the PUBLISHED BOARD show a reader a mangled product name?
#
# WHY THIS EXISTS (2026-09-05). The estate has had encoding defences for a while and every one of them
# watches an INPUT: guards.ps1 check 0d pins commodities.json's encoding, capture-lib repairs on ingest,
# heal-mojibake backfills the store files, build-fareway-regular repairs its own names. Nothing looked at
# the surface the shopper actually reads. So on comparison-2026-09-02 five live cells across three stores
# carried mangled names while every guard read green:
#     jarred-gravy      Hy-Vee      "Campbell" + 5 generations of mojibake + "s Turkey Gravy, 10.5 oz Can"
#                                   (117 characters for a 36-character name)
#     dried-cranberries Hy-Vee      Ocean Spray / Craisins registered signs, 4 generations deep
#     pesto             Hy-Vee      "Filippo Berio" + A-circumflex + registered sign
#     pickled-jalapenos Fareway     "La Coste" + A-tilde + n-tilde + "a"
#     shampoo           Sam's Club  "TRESemm" + A-tilde + copyright sign
# The last one is why an input-only guard can never be enough: sams-deals-2026-07-29.json is CLEAN on disk.
# It begins 7B 0D 0A with no BOM while every other Sam's slice begins EF BB BF, and Windows PowerShell 5.1
# decodes a BOM-less file as the ANSI codepage, so the ENGINE manufactured that name while reading a
# perfectly good file. No amount of healing the inputs would have found it. The board is the only place
# where every one of these is visible at once, which is exactly why the check belongs here.
#
# ADVISORY BY DESIGN, FOR NOW. It exits 2 and alerts rather than blocking publish, because on the day it
# shipped there were five real findings and blocking would have held a board whose PRICES were all correct.
# Once it reads 0 on a published board it is a candidate for guards.ps1 (open question for Brad, plan
# 2026-09-05). A cosmetic-looking defect is not cosmetic here: audit-name-drift compares the board item
# against the stored link name WORD BY WORD, so one side mangled and the other not reads as a wrong product.
#
# EXIT 0 clean, 2 findings, 3 BLIND (no board, unparseable, or zero rows examined). Three, not zero: a
# board with no rows is the shape where a counter-based check reports "0 findings" and means "I looked at
# nothing", which is how five structurally dead guards were found here in one sweep.
#
# Run:  .\audit-board-mojibake.ps1
#       .\audit-board-mojibake.ps1 -SelfTest
param([switch]$SelfTest, [string]$OutDir, [string]$Board, [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')   # Read-JsonFile: this guard must not itself read through the codepage bug it watches for

# THE SIGNATURE, and why it is these three lead bytes and nothing else.
# UTF-8 read as Windows-1252 turns every non-ASCII character into a sequence that STARTS with one of
# A-tilde (C3, for the Latin-1 range), A-circumflex (C2, for punctuation and symbols like the registered
# sign) or a-circumflex (E2, for the General Punctuation block: curly quotes, dashes, the trademark sign).
# Requiring a following byte in the continuation range is what keeps real names silent - "La Costena" with
# a real n-tilde, "TRESemme" with a real e-acute and "Filippo Berio" with a real registered sign carry none
# of those lead bytes at all. This is deliberately the same shape capture-lib's MOJI_SIGNATURE uses, but
# tightened with the follower, because THIS check names rows in an alert and a false positive here sends a
# human to look at a correct product.
$script:BOARD_MOJI = "[$([char]0x00C3)][$([char]0x0080)-$([char]0x00BF)]|$([char]0x00E2)$([char]0x20AC)|[$([char]0x00C2)][$([char]0x00A0)-$([char]0x00BF)]"

function Test-BoardMojibake([string]$Name) {
  if ([string]::IsNullOrEmpty($Name)) { return $false }
  return ($Name -match $script:BOARD_MOJI)
}

# Every reader-facing name a comparison document carries: the commodity label and each store's item.
function Get-BoardMojibakeFindings {
  param([object]$Doc)
  $rows = @()
  $examined = 0
  if (-not $Doc -or -not $Doc.PSObject.Properties['comparison']) { return [pscustomobject]@{ examined = 0; findings = @() } }
  foreach ($c in @($Doc.comparison)) {
    foreach ($st in @($c.stores)) {
      $nm = [string]$st.item
      if (-not $nm) { continue }
      $examined++
      if (Test-BoardMojibake $nm) {
        $rows += [pscustomobject]@{ id = [string]$c.id; store = [string]$st.store; item = $nm }
      }
    }
  }
  return [pscustomobject]@{ examined = $examined; findings = $rows }
}

# ------------------------------------------------------------------ self-test
if ($SelfTest) {
  $fail = 0
  function _T($label, $cond) { if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ } }

  # THE FROZEN FOUNDING ROWS. Copied byte for byte out of comparison-2026-09-02.json on the day the check
  # was written and never re-read from a live board: the bug these encode is being healed, so regenerating
  # them from the board would erase the very thing they exist to catch and the test would pass by finding
  # nothing. Built from char codes so that this file's own encoding cannot become the fixture.
  function _S([int[]]$cp) { -join ($cp | ForEach-Object { [char]$_ }) }
  $A3 = [char]0x00C3; $A2 = [char]0x00C2
  # jarred-gravy / Hy-Vee, comparison-2026-09-02.json: 117 characters for a 36-character name, five
  # generations deep. Stored as codepoints so no re-encoding of THIS file can ever alter the fixture.
  $campbell = _S @(
    0x0043,0x0061,0x006D,0x0070,0x0062,0x0065,0x006C,0x006C,0x00C3,0x0192,0x00C6,0x2019,
    0x00C3,0x2020,0x00E2,0x20AC,0x2122,0x00C3,0x0192,0x00E2,0x20AC,0x0161,0x00C3,0x201A,
    0x00C2,0x00A2,0x00C3,0x0192,0x00C6,0x2019,0x00C3,0x201A,0x00C2,0x00A2,0x00C3,0x0192,
    0x00C2,0x00A2,0x00C3,0x00A2,0x00E2,0x20AC,0x0161,0x00C2,0x00AC,0x00C3,0x2026,0x00C2,
    0x00A1,0x00C3,0x0192,0x00E2,0x20AC,0x0161,0x00C3,0x201A,0x00C2,0x00AC,0x00C3,0x0192,
    0x00C6,0x2019,0x00C3,0x201A,0x00C2,0x00A2,0x00C3,0x0192,0x00C2,0x00A2,0x00C3,0x00A2,
    0x00E2,0x20AC,0x0161,0x00C2,0x00AC,0x00C3,0x2026,0x00C2,0x00BE,0x00C3,0x0192,0x00E2,
    0x20AC,0x0161,0x00C3,0x201A,0x00C2,0x00A2,0x0073,0x0020,0x0054,0x0075,0x0072,0x006B,
    0x0065,0x0079,0x0020,0x0047,0x0072,0x0061,0x0076,0x0079,0x002C,0x0020,0x0031,0x0030,
    0x002E,0x0035,0x0020,0x006F,0x007A,0x0020,0x0043,0x0061,0x006E)
  # dried-cranberries / Hy-Vee, same board: 148 characters, four generations, two registered signs.
  $craisins = _S @(
    0x004F,0x0063,0x0065,0x0061,0x006E,0x0020,0x0053,0x0070,0x0072,0x0061,0x0079,0x00C3,
    0x0192,0x00C6,0x2019,0x00C3,0x2020,0x00E2,0x20AC,0x2122,0x00C3,0x0192,0x00C2,0x00A2,
    0x00C3,0x00A2,0x00E2,0x20AC,0x0161,0x00C2,0x00AC,0x00C3,0x2026,0x00C2,0x00A1,0x00C3,
    0x0192,0x00C6,0x2019,0x00C3,0x00A2,0x00E2,0x201A,0x00AC,0x00C5,0x00A1,0x00C3,0x0192,
    0x00E2,0x20AC,0x0161,0x00C3,0x201A,0x00C2,0x00AE,0x0020,0x0043,0x0072,0x0061,0x0069,
    0x0073,0x0069,0x006E,0x0073,0x00C3,0x0192,0x00C6,0x2019,0x00C3,0x2020,0x00E2,0x20AC,
    0x2122,0x00C3,0x0192,0x00C2,0x00A2,0x00C3,0x00A2,0x00E2,0x20AC,0x0161,0x00C2,0x00AC,
    0x00C3,0x2026,0x00C2,0x00A1,0x00C3,0x0192,0x00C6,0x2019,0x00C3,0x00A2,0x00E2,0x201A,
    0x00AC,0x00C5,0x00A1,0x00C3,0x0192,0x00E2,0x20AC,0x0161,0x00C3,0x201A,0x00C2,0x00AE,
    0x0020,0x004F,0x0072,0x0069,0x0067,0x0069,0x006E,0x0061,0x006C,0x0020,0x0044,0x0072,
    0x0069,0x0065,0x0064,0x0020,0x0043,0x0072,0x0061,0x006E,0x0062,0x0065,0x0072,0x0072,
    0x0069,0x0065,0x0073,0x002C,0x0020,0x0044,0x0072,0x0069,0x0065,0x0064,0x0020,0x0046,
    0x0072,0x0075,0x0069,0x0074)
  $costena = 'La Coste' + $A3 + [char]0x00B1 + 'a Jalapeno Nacho Slices, Pickled'
  $tresemme = 'TRESemm' + $A3 + [char]0x00A9 + ' Ultimate Moisture Shampoo & Conditioner, 39 fl. oz., 2 pk.'
  $berio = 'Filippo Berio' + $A2 + [char]0x00AE + ' Classic Pesto 6.7 oz. Jar'

  # MUST FIRE, one per lead byte, so no single branch can rot unnoticed.
  _T 'MUST FIRE: the 5-generation Campbell row is a finding' (Test-BoardMojibake $campbell)
  _T 'MUST FIRE: the Fareway La Costena row is a finding'    (Test-BoardMojibake $costena)
  _T 'MUST FIRE: the Sam''s TRESemme row is a finding'       (Test-BoardMojibake $tresemme)
  _T 'MUST FIRE: the Hy-Vee Filippo Berio row is a finding'  (Test-BoardMojibake $berio)

  # CLEAN TWINS: the SAME five products with their real characters. If any of these fires the signature is
  # too broad, and a check that flags correct names is worse than no check - it teaches a reader to ignore it.
  foreach ($clean in @(
      ('Campbell' + [char]0x2019 + 's Turkey Gravy, 10.5 oz Can'),
      ('La Coste' + [char]0x00F1 + 'a Jalapeno Nacho Slices, Pickled'),
      ('TRESemm' + [char]0x00E9 + ' Ultimate Moisture Shampoo & Conditioner, 39 fl. oz., 2 pk.'),
      ('Filippo Berio' + [char]0x00AE + ' Classic Pesto 6.7 oz. Jar'),
      ('Ocean Spray' + [char]0x00AE + ' Craisins' + [char]0x00AE + ' Original Dried Cranberries, Dried Fruit'),
      ('Nestl' + [char]0x00E9 + ' Carnation evaporated milk, 12 oz.'),
      ('Ensue' + [char]0x00F1 + 'o Max Liquid Fabric Softener, Spring Fresh 330 loads, 236 fl. oz.'),
      ('Member' + [char]0x2019 + 's Mark Wildflower Pure Premium Honey, 48 oz.'),
      'Great Value Gluten-Free Vegetable Broth, 32 oz Carton')) {
    _T ('CLEAN TWIN stays silent: ' + $clean.Substring(0, [math]::Min(34, $clean.Length))) (-not (Test-BoardMojibake $clean))
  }

  # THE WALKER, on a board-shaped document: it must find the two planted rows and name them, and it must
  # count every name it looked at so a zero-row board can be told apart from a clean one.
  $fixture = [pscustomobject]@{ comparison = @(
    [pscustomobject]@{ id = 'jarred-gravy'; stores = @(
      [pscustomobject]@{ store = 'Hy-Vee'; item = $campbell },
      [pscustomobject]@{ store = "Baker's"; item = 'Heinz HomeStyle Turkey Gravy, Jar' }) },
    [pscustomobject]@{ id = 'pickled-jalapenos'; stores = @(
      [pscustomobject]@{ store = 'Fareway'; item = $costena },
      [pscustomobject]@{ store = 'Walmart'; item = ('La Coste' + [char]0x00F1 + 'a Pickled Sliced Jalapenos, 28 oz') }) }
  ) }
  $r = Get-BoardMojibakeFindings -Doc $fixture
  _T 'walker examined all four names' ($r.examined -eq 4)
  _T 'walker found exactly the two mangled rows' ($r.findings.Count -eq 2)
  _T 'walker names the commodity and the store' (
    @($r.findings | Where-Object { $_.id -eq 'jarred-gravy' -and $_.store -eq 'Hy-Vee' }).Count -eq 1 -and
    @($r.findings | Where-Object { $_.id -eq 'pickled-jalapenos' -and $_.store -eq 'Fareway' }).Count -eq 1)

  # CLEAN TWIN for the walker: the same fixture with every name healed reports zero AND still examined four.
  $healed = [pscustomobject]@{ comparison = @(
    [pscustomobject]@{ id = 'jarred-gravy'; stores = @(
      [pscustomobject]@{ store = 'Hy-Vee'; item = ('Campbell' + [char]0x2019 + 's Turkey Gravy, 10.5 oz Can') },
      [pscustomobject]@{ store = "Baker's"; item = 'Heinz HomeStyle Turkey Gravy, Jar' }) },
    [pscustomobject]@{ id = 'pickled-jalapenos'; stores = @(
      [pscustomobject]@{ store = 'Fareway'; item = ('La Coste' + [char]0x00F1 + 'a Jalapeno Nacho Slices, Pickled') },
      [pscustomobject]@{ store = 'Walmart'; item = ('La Coste' + [char]0x00F1 + 'a Pickled Sliced Jalapenos, 28 oz') }) }
  ) }
  $rc = Get-BoardMojibakeFindings -Doc $healed
  _T 'healed twin reports zero findings' ($rc.findings.Count -eq 0)
  _T 'healed twin still examined four names (0 findings is not the same as 0 rows)' ($rc.examined -eq 4)

  # BLIND: an empty board must not read as clean.
  $empty = Get-BoardMojibakeFindings -Doc ([pscustomobject]@{ comparison = @() })
  _T 'an empty board examines zero names, which the caller reports as BLIND' ($empty.examined -eq 0)

  # THE HEALER MUST REACH THE DEPTH THE BOARD ACTUALLY HIT. This check and heal-mojibake are two halves of
  # one loop: if Repair-Mojibake stops short, this audit stays red forever and the only way to make it green
  # is to weaken the signature. The cap was 4 the day the 5-generation Campbell row was found, so the healer
  # returned a still-mangled name and reported success.
  . (Join-Path $root 'capture-lib.ps1')
  _T 'Repair-Mojibake fully unwinds the 5-generation row' (
    (Repair-Mojibake $campbell) -eq ('Campbell' + [char]0x2019 + 's Turkey Gravy, 10.5 oz Can'))
  _T 'Repair-Mojibake fully unwinds the 4-generation registered signs' (
    (Repair-Mojibake $craisins) -eq ('Ocean Spray' + [char]0x00AE + ' Craisins' + [char]0x00AE + ' Original Dried Cranberries, Dried Fruit'))
  # ...and the healed output of every founding row must then be silent to this check, or the two halves
  # disagree and the board can never go green without weakening one of them.
  foreach ($m in @($campbell, $craisins, $costena, $tresemme, $berio)) {
    _T ('healed founding row is silent: ' + (Repair-Mojibake $m).Substring(0, 20)) (-not (Test-BoardMojibake (Repair-Mojibake $m)))
  }
  _T 'Repair-Mojibake leaves a real registered sign alone' (
    (Repair-Mojibake ('Filippo Berio' + [char]0x00AE + ' Classic Pesto 6.7 oz. Jar')) -eq ('Filippo Berio' + [char]0x00AE + ' Classic Pesto 6.7 oz. Jar'))

  if ($fail) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output 'SELF-TEST PASS'
  exit 0
}

# ------------------------------------------------------------------ live run
if (-not $Board) {
  $bf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
  if ($bf) { $Board = $bf.FullName }
}
if (-not $Board -or -not (Test-Path $Board)) {
  Write-Output 'audit-board-mojibake: BLIND - no comparison board found to examine'
  exit 3
}
$doc = $null
try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($Board)) } catch { $doc = $null }
if (-not $doc) {
  Write-Output ('audit-board-mojibake: BLIND - could not parse ' + (Split-Path $Board -Leaf))
  exit 3
}
$res = Get-BoardMojibakeFindings -Doc $doc
if ($res.examined -eq 0) {
  Write-Output ('audit-board-mojibake: BLIND - ' + (Split-Path $Board -Leaf) + ' carries zero named store rows')
  exit 3
}
# ---- THE RATCHET (2026-09-05, Brad's call) ---------------------------------------------------------------
# Advisory could not stay: audit-name-drift compares the board item name against the stored link name WORD
# BY WORD, so one side mangled and the other not reads as a WRONG PRODUCT - a corrupted name manufactures
# false findings in a different guard. And it compounds silently: the Campbell's row was five generations
# deep, 117 characters for a 36-character name, before anyone looked.
# Blocking outright could not ship either: on the day this was written there were five real findings, and a
# board whose PRICES are all correct must not be held hostage to a bad apostrophe.
# So it is a ratchet, the same shape as audit-tile-integrity and audit-band-censorship. The baseline is 0
# today, which means both rules are currently identical and this costs nothing - and the moment a name that
# was clean yesterday is mangled today, that is a LIVE reader bug and it blocks.
$blF = Join-Path $OutDir 'board-mojibake-baseline.json'
$base = $null
if (Test-Path $blF) { try { $base = [int]((Read-JsonFile $blF).count) } catch { $base = $null } }
$count = $res.findings.Count
if ($null -eq $base) {
  # A BLIND run never reaches here - every could-not-read path above exits 3 first - so a baseline written
  # at this point is always taken from a board that was actually examined.
  @{ generated = (Get-Date).ToString('s'); count = $count; note = 'High-water mark for the board-mojibake ratchet, set 2026-09-05. May only go DOWN. A run above it is a NEW mangled name, i.e. a live reader bug, and hard-fails.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
  Write-Output ("audit-board-mojibake: baseline written at $count. From here the number may only go DOWN.")
  $base = $count
}
if ($count -lt $base) {
  @{ generated = (Get-Date).ToString('s'); count = $count; note = 'High-water mark for the board-mojibake ratchet. May only go DOWN.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
  Write-Output ("audit-board-mojibake: ratchet tightened to $count (was $base).")
  $base = $count
}
if (-not $res.findings.Count) {
  Write-Output ('audit-board-mojibake: clean - ' + $res.examined + ' board name(s) examined in ' + (Split-Path $Board -Leaf) + ', 0 mangled')
  exit 0
}
$lines = @()
foreach ($f in $res.findings) {
  $lines += ('  ' + $f.id.PadRight(26) + ' ' + $f.store.PadRight(12) + ' ' + $f.item)
}
Write-Output ('audit-board-mojibake: ' + $res.findings.Count + ' mangled product name(s) on ' + (Split-Path $Board -Leaf) + ' (' + $res.examined + ' examined)')
$lines | ForEach-Object { Write-Output $_ }
Write-Output 'These names are what the shopper reads and what audit-name-drift compares word-by-word against the stored link name. Fix the READER that produced them (a BOM-less input read without -Encoding), then run heal-mojibake.ps1 -Apply and rebuild.'
if (-not $Quiet) {
  try {
    . (Join-Path $root 'alert-lib.ps1')
    $body = "The published board carries product names that were mangled by an encoding round-trip.`n`n" +
            ($lines -join "`n") + "`n`nBoard: " + (Split-Path $Board -Leaf) + "  names examined: " + $res.examined +
            "`n`nThis is the reader, not the store: check for a JSON input read without -Encoding (Windows PowerShell 5.1 decodes a BOM-less UTF-8 file as the ANSI codepage), then heal-mojibake.ps1 -Apply and rebuild."
    Send-Alert -Subject ('Grocery: ' + $res.findings.Count + ' board product name(s) are mangled - encoding') -Body $body | Out-Null
  } catch {}
}
# AT OR BELOW the known backlog is exit 1 (findings, reported, does not block). ABOVE it is exit 2, which
# guards.ps1 treats as a hard fail - a name that was clean on the last board and is mangled on this one is
# a reader bug happening RIGHT NOW, and it will bake itself one generation deeper on every rebuild.
if ($count -gt $base) {
  Write-Output ("audit-board-mojibake: RATCHET BROKEN - $count mangled name(s) now, baseline $base. A name that was clean is now corrupted, so a reader is actively mangling input. Find it with audit-json-readers.ps1, fix it with Read-JsonFile (lib\json-io.ps1), then heal-mojibake.ps1 -Apply and rebuild.")
  exit 2
}
Write-Output ("audit-board-mojibake: $count mangled name(s) against a baseline of $base - the known backlog, not a new regression.")
exit 1
