$ErrorActionPreference='Stop'
$f='C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\f3644374-5e4d-4c5e-a7e6-7ac3b89873f9\tasks\wl5d30w0c.output'
$doc=ConvertFrom-Json ([IO.File]::ReadAllText($f))
$conf=@($doc.confirmed)
Write-Output ("CONFIRMED findings: "+$conf.Count)
Write-Output ("  fix_safe=true: "+@($conf|Where-Object{$_.fix_safe}).Count+"   fix_safe=false: "+@($conf|Where-Object{-not $_.fix_safe}).Count)
Write-Output ""
Write-Output "=== by severity x issue_type ==="
$conf | Group-Object severity | Sort-Object Name | ForEach-Object {
  Write-Output ("  severity="+$_.Name+"  ("+$_.Count+")")
  $_.Group | Group-Object issue_type | Sort-Object Count -Descending | ForEach-Object { Write-Output ("      "+$_.Name.PadRight(18)+" "+$_.Count) }
}
Write-Output ""
Write-Output "=== HIGH severity (all) ==="
$conf | Where-Object{$_.severity -eq 'high'} | ForEach-Object { Write-Output ("  ["+$_.issue_type+"] "+$_.commodity+" | "+$_.summary) ; Write-Output ("      FIX: "+$_.suggested_fix+"   safe="+$_.fix_safe) }
# dump a clean csv-ish list of ALL confirmed for review
$rows=@($conf | ForEach-Object { [pscustomobject]@{sev=$_.severity;safe=$_.fix_safe;type=$_.issue_type;commodity=$_.commodity;fix=$_.suggested_fix;summary=$_.summary} })
$rows | ConvertTo-Json -Depth 4 | Set-Content 'C:\Codex\income\grocery\out\audit\confirmed-clean.json' -Encoding UTF8
Write-Output ""
Write-Output ("wrote confirmed-clean.json ("+$rows.Count+" rows)")