<#
  apply-prose-field.ps1 - KEY-SCOPED prose updater for db\recipes specs.

  Applies a {slug: newText} map to ONE top-level string field across spec files WITHOUT
  re-serializing the JSON (spec prose carries \uXXXX escapes that a full parse+dump would
  rewrite; the standing rule is key-scoped text edits only).

  Usage: .\apply-prose-field.ps1 -Field shop_smart -MapFile <path to {slug:text} json> [-DryRun]

  Each new value is JSON-escaped via ConvertTo-Json (string overload), then spliced into the
  raw file text over the existing "<field>": "..." value. Refuses a file where the field is
  absent or appears more than once. Prints a per-slug result; exit 1 if any slug failed.
#>
param(
  [Parameter(Mandatory=$true)][string]$Field,
  [Parameter(Mandatory=$true)][string]$MapFile,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\meal-prep' }
$specDir = Join-Path $root 'db\recipes'
if ($Field -notmatch '^[a-z_]+$') { throw "unsafe field name '$Field'" }

$map = Get-Content $MapFile -Raw | ConvertFrom-Json
# the field may be a STRING or an ARRAY of strings (both shapes exist across the 513 specs);
# match either so the splice replaces the whole existing value
$rx = [regex]('(?s)("' + $Field + '"\s*:\s*)(?:"(?:[^"\\]|\\.)*"|\[(?:[^\[\]"]|"(?:[^"\\]|\\.)*")*\])')
$ok = 0; $fail = 0
foreach ($p in $map.PSObject.Properties) {
  $slug = $p.Name
  $f = Join-Path $specDir ($slug + '.json')
  if (-not (Test-Path $f)) { Write-Output ("FAIL  " + $slug + " - no spec file"); $fail++; continue }
  $raw = [IO.File]::ReadAllText($f)
  $ms = $rx.Matches($raw)
  if ($ms.Count -ne 1) { Write-Output ("FAIL  " + $slug + " - field '" + $Field + "' matched " + $ms.Count + "x (need exactly 1)"); $fail++; continue }
  # string -> quoted escaped literal; array -> compact JSON array of strings (keep the spec's own shape)
  $escaped = if ($p.Value -is [System.Array]) { (ConvertTo-Json @($p.Value) -Compress) } else { ($p.Value | ConvertTo-Json) }
  $newRaw = $rx.Replace($raw, ('${1}' + ($escaped -replace '\$','$$$$')), 1)
  try { $null = $newRaw | ConvertFrom-Json } catch { Write-Output ("FAIL  " + $slug + " - result no longer parses: " + $_.Exception.Message); $fail++; continue }
  if ($DryRun) { Write-Output ("DRY   " + $slug) ; $ok++; continue }
  [IO.File]::WriteAllText($f, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
  $ok++
}
Write-Output ("applied '" + $Field + "': " + $ok + " ok, " + $fail + " failed")
if ($fail) { exit 1 } else { exit 0 }
