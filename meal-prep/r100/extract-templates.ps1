# extract-templates.ps1 - Pulls the EXACT scaler-widget template bytes out of a live recipe card
# so the generator never retypes them (retyping = drift risk). Produces:
#   tpl-scaler-prefix.html  = <!--SMP-SCALER--> ... <script type="application/json" class="smp-sc-data">
#   tpl-scaler-suffix.html  = </script></div><div class="smp-cp"> ... <!--/SMP-SCALER-->
# Also extracts the live smp-sc-data JSON and the prose block for the fidelity test.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$body = [IO.File]::ReadAllText((Join-Path $here '..\_sample-recipe-body.html'), [Text.Encoding]::UTF8)

$startTag = '<!--SMP-SCALER-->'
$dataOpen = '<script type="application/json" class="smp-sc-data">'
$endTag   = '<!--/SMP-SCALER-->'

$iStart = $body.IndexOf($startTag);            if($iStart -lt 0){ throw 'no SMP-SCALER start' }
$iData  = $body.IndexOf($dataOpen, $iStart);   if($iData  -lt 0){ throw 'no smp-sc-data open' }
$iDataEnd = $body.IndexOf('</script>', $iData);if($iDataEnd -lt 0){ throw 'no data close' }
$iEnd   = $body.IndexOf($endTag, $iDataEnd);   if($iEnd   -lt 0){ throw 'no SMP-SCALER end' }
$iEnd  += $endTag.Length

$prefix = $body.Substring($iStart, $iData + $dataOpen.Length - $iStart)
$dataJson = $body.Substring($iData + $dataOpen.Length, $iDataEnd - ($iData + $dataOpen.Length))
$suffix = $body.Substring($iDataEnd, $iEnd - $iDataEnd)

[IO.File]::WriteAllText((Join-Path $here 'tpl-scaler-prefix.html'), $prefix, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $here 'tpl-scaler-suffix.html'), $suffix, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $here 'live-scaler-data.json'), $dataJson, (New-Object Text.UTF8Encoding($false)))

# prose block: from the stat line to the last </p> before a kg-card-end
$iProse = $body.IndexOf('<p><strong>Makes 14 servings')
if($iProse -lt 0){ throw 'no prose start' }
$iProseEnd = $body.IndexOf('<!--kg-card-end', $iProse)
$prose = $body.Substring($iProse, $iProseEnd - $iProse).TrimEnd()
[IO.File]::WriteAllText((Join-Path $here 'live-prose.html'), $prose, (New-Object Text.UTF8Encoding($false)))

Write-Output ("prefix={0}B suffix={1}B data={2}B prose={3}B" -f $prefix.Length, $suffix.Length, $dataJson.Length, $prose.Length)
