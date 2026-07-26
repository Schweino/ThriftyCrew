# build-canon-rules.ps1 (r300) - Builds r300-canon-rules.json:
#   [authored r300 rules] + [r100 canon-rules re-based against the current food DB]
# Re-basing: any r100 target "NEW:X" where X now exists in food-macros-db.json becomes "X"
# (stops r300 from re-minting items added to the DB after the r100 run). Regexes and order
# are untouched, so r100 matching semantics are preserved exactly.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$authored = (Get-Content (Join-Path $here 'r300-canon-rules.authored.json') -Raw -Encoding utf8 | ConvertFrom-Json)
$r100 = (Get-Content (Join-Path $here '..\r100\canon-rules.json') -Raw -Encoding utf8 | ConvertFrom-Json).rules
$dbItems = ((Get-Content (Join-Path $here '..\food-macros-db.json') -Raw -Encoding utf8 | ConvertFrom-Json).items | ForEach-Object { $_.item })
$dbSet = @{}; foreach ($i in $dbItems) { $dbSet[$i] = 1 }

$out = @()
$rebased = 0
foreach ($r in $authored.rules) {
    $target = $r[1]
    if ($target -like 'NEW:*') {
        $name = $target.Substring(4)
        if ($dbSet.ContainsKey($name)) { $target = $name; $rebased++ }
    }
    $out += ,@($r[0], $target)
}
$authoredCount = $out.Count
foreach ($r in $r100) {
    $target = $r[1]
    $rx = $r[0]
    # Targeted latent-bug patch (2026-07-25): bare 'sage' alternative matches 'sausages'.
    # Applied to the r300 COPY only; r100's own file stays untouched.
    if ($rx -eq 'rosemary|sage') { $rx = 'rosemary|\bsage\b' }
    if ($target -like 'NEW:*') {
        $name = $target.Substring(4)
        if ($dbSet.ContainsKey($name)) { $target = $name; $rebased++ }
    }
    $out += ,@($rx, $target)
}

# Validate every non-NEW, non-DROP target against the DB
foreach ($r in $out) {
    $t = $r[1]
    if ($t -ne 'DROP' -and -not $t.StartsWith('NEW:') -and -not $dbSet.ContainsKey($t)) {
        throw ("target not in food DB: '{0}' (rule regex '{1}')" -f $t, $r[0])
    }
}

$doc = [ordered]@{
    readme = ("R300 canon rules, built {0} by build-canon-rules.ps1. Rules 0-{1} are authored r300 rules (see r300-canon-rules.authored.json); rules {2}+ are the r100 set re-based against the current food DB ({3} NEW: targets now exist in the DB and were rewritten to plain item names). First match wins, case-insensitive. Rebuild after DB or authored-rule changes." -f (Get-Date -Format 'yyyy-MM-dd'), ($authoredCount - 1), $authoredCount, $rebased)
    rules = $out
}
$doc | ConvertTo-Json -Depth 4 | Out-File (Join-Path $here 'r300-canon-rules.json') -Encoding utf8
Write-Output ("authored: {0}   r100 appended: {1} (rebased {2})   total: {3}" -f $authoredCount, $r100.Count, $rebased, $out.Count)
