# build-mycrew.ps1
# Concatenates the /my-crew/ template with the two already-generated datasets:
#   grocery\staples-data.js  (var ST=...)
#   meal-prep\dinner-data.js (var DIN=...)
# replacing the //__DATA__ marker, and writes my-crew-tool.html (UTF-8, no BOM).
# Usage: powershell -File C:\Codex\income\build-mycrew.ps1

$ErrorActionPreference = 'Stop'
$dir = 'C:\Codex\income'

$tplPath = Join-Path $dir 'my-crew-template.html'
$stPath  = Join-Path $dir 'grocery\staples-data.js'
$dinPath = Join-Path $dir 'meal-prep\dinner-data.js'
$outPath = Join-Path $dir 'my-crew-tool.html'

$tpl = [System.IO.File]::ReadAllText($tplPath)
$st  = [System.IO.File]::ReadAllText($stPath).TrimStart([char]0xFEFF).Trim()
$din = [System.IO.File]::ReadAllText($dinPath).TrimStart([char]0xFEFF).Trim()

if ($tpl -notmatch '//__DATA__') { throw 'Marker //__DATA__ not found in template.' }
if ($st -notmatch '^var ST=')  { throw 'staples-data.js does not start with "var ST=".' }
if ($din -notmatch '^var DIN=') { throw 'dinner-data.js does not start with "var DIN=".' }

$data = $st + "`n" + $din
$out = $tpl.Replace('//__DATA__', $data)

# Sanity checks: file tail must be </script> then </div>; no em dashes anywhere.
$tail = $out.TrimEnd()
if (-not $tail.EndsWith("</script>`n</div>") -and -not $tail.EndsWith("</script>`r`n</div>")) {
    if (-not ($tail -match '</script>\s*</div>$')) { throw 'Output does not end with </script> then </div>.' }
}
if ($out.Contains([string][char]0x2014)) { throw 'Em dash found in output.' }

[System.IO.File]::WriteAllText($outPath, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Built {0} ({1:N0} bytes)" -f $outPath, (Get-Item $outPath).Length)
