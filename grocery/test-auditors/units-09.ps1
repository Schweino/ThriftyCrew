# units-09.ps1 - dot-sourced by units-03.ps1 at u051v's old place (split 2026-09-28 under ops\audit-file-size-budget.ps1).
# Runs in test-auditors.ps1's scope: $root, Ok, Bad, Use-Unit and Get-TcProductionText come from there.
# (u051v) THE VERDICT FINGERPRINT MEASURES CONTENT, NOT LINE ENDINGS (2026-09-28, queue 2026-09-27-f50b7a). On 2026-09-27
# an autostash pull round-tripped the chain's dirty CRLF product-urls.json to LF with its content unchanged, the raw-byte
# fingerprint moved, and a board guards had passed was withheld and filed under guards-blocked. Driven over a fixture
# tree through the real writer and reader, never a source grep of the hash.
if (Use-Unit 'u051v-chain-verdict-hashes-content' -Reads 'lib/chain-verdict-lib.ps1', 'lib/json-io.ps1', 'grocery/capture-run.ps1', 'grocery/test-auditors/units-09.ps1') {
$cvTmp = Join-Path ([IO.Path]::GetTempPath()) ('cvf-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
try {
  . (Join-Path (Split-Path $root -Parent) 'lib\chain-verdict-lib.ps1')
  . (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')   # Read-JsonFile, named here so this piece resolves on its own
  $cvG = Join-Path $cvTmp 'grocery'
  New-Item -ItemType Directory -Path (Join-Path $cvG 'out') -Force -ErrorAction Stop | Out-Null
  $cvCR = [string][char]13; $cvLF = [string][char]10
  $cvUrlsCrlf = '{' + $cvCR + $cvLF + '  "milk": "https://example.test/a",' + $cvCR + $cvLF + '  "eggs": "https://example.test/b"' + $cvCR + $cvLF + '}' + $cvCR + $cvLF
  $cvNoBom = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $cvG 'commodities.json'), ('{"commodities":[{"id":"milk","band":1}]}' + $cvLF), $cvNoBom)
  [IO.File]::WriteAllText((Join-Path $cvG 'known-wrong.json'), ('[]' + $cvLF), $cvNoBom)
  [IO.File]::WriteAllText((Join-Path $cvG 'board-price-overrides.json'), ('{}' + $cvLF), $cvNoBom)
  [IO.File]::WriteAllText((Join-Path $cvG 'product-urls.json'), $cvUrlsCrlf, $cvNoBom)
  [IO.File]::WriteAllText((Join-Path $cvG 'out\comparison-2026-09-27.json'), ('{"rows":[]}' + $cvLF), $cvNoBom)
  $cvOut = Join-Path $cvG 'out'
  $cvDay = '2026-09-27'
  [void](Write-ChainVerdict -Repo $cvTmp -OutDir $cvOut -Date $cvDay -GuardsRc 0 -FeedRefused '')
  $cvRec = Read-JsonFile (Join-Path $cvOut 'chain-verdict.json')
  if ([string]$cvRec.inputs_hash_basis -eq 'json-cr-stripped-v1') { Ok 'u051v: the verdict records the hash basis it was written on (json-cr-stripped-v1)' }
  else { Bad ('u051v: the verdict records hash basis ''' + [string]$cvRec.inputs_hash_basis + ''' - a reader cannot tell which basis the fingerprint is on') }
  $cv0 = Read-ChainVerdictStatus -Repo $cvTmp -OutDir $cvOut -Today $cvDay
  if ($cv0.status -eq 'PASS') { Ok 'u051v: an untouched tree reads PASS' } else { Bad ('u051v: an untouched tree reads ' + $cv0.status + ': ' + $cv0.why) }
  # MUST NOT FIRE (the 2026-09-27 shape, frozen): the same content rewritten LF, exactly what the autostash round-trip did
  [IO.File]::WriteAllText((Join-Path $cvG 'product-urls.json'), $cvUrlsCrlf.Replace($cvCR, ''), $cvNoBom)
  $cv1 = Read-ChainVerdictStatus -Repo $cvTmp -OutDir $cvOut -Today $cvDay
  if ($cv1.status -eq 'PASS' -and $cv1.fingerprint_now -eq $cv0.fingerprint_now) { Ok 'u051v: MUST NOT FIRE - a CRLF product-urls.json rewritten LF with the same content still reads PASS, fingerprint unchanged' }
  else { Bad ('u051v: MUST NOT FIRE - an EOL-only rewrite of product-urls.json read ' + $cv1.status + ' (' + $cv0.fingerprint_now + ' -> ' + $cv1.fingerprint_now + '): the 2026-09-27 withhold is back') }
  # CLEAN TWIN: drop one link after the verdict (the real prune shape) - the normalisation must not blind the content check
  [IO.File]::WriteAllText((Join-Path $cvG 'product-urls.json'), ('{' + $cvLF + '  "milk": "https://example.test/a"' + $cvLF + '}' + $cvLF), $cvNoBom)
  $cv2 = Read-ChainVerdictStatus -Repo $cvTmp -OutDir $cvOut -Today $cvDay
  $cv2m = @($cv2.moved)
  if ($cv2.status -eq 'STALE-INPUTS' -and $cv2m.Count -eq 1 -and $cv2m[0] -eq 'grocery/product-urls.json' -and $cv2.why -match 'product-urls\.json') { Ok 'u051v: CLEAN TWIN - a dropped link after the verdict reads STALE-INPUTS naming grocery/product-urls.json' }
  else { Bad ('u051v: CLEAN TWIN - a dropped link read ' + $cv2.status + ' moved=[' + ($cv2m -join ',') + ']: the CR strip blinded the content check') }
  # MUST FIRE: one value changed in an LF commodities.json -> STALE-INPUTS naming exactly that path
  [IO.File]::WriteAllText((Join-Path $cvG 'product-urls.json'), $cvUrlsCrlf, $cvNoBom)
  [IO.File]::WriteAllText((Join-Path $cvG 'commodities.json'), ('{"commodities":[{"id":"milk","band":2}]}' + $cvLF), $cvNoBom)
  $cv3 = Read-ChainVerdictStatus -Repo $cvTmp -OutDir $cvOut -Today $cvDay
  $cv3m = @($cv3.moved)
  if ($cv3.status -eq 'STALE-INPUTS' -and $cv3m.Count -eq 1 -and $cv3m[0] -eq 'grocery/commodities.json' -and -not $cv3.ship_ok) { Ok 'u051v: MUST FIRE - one value changed in commodities.json reads STALE-INPUTS with moved = grocery/commodities.json, and does not ship' }
  else { Bad ('u051v: MUST FIRE - a commodities.json value change read ' + $cv3.status + ' moved=[' + ($cv3m -join ',') + '] ship_ok=' + $cv3.ship_ok) }
  # MUST FIRE: a verdict on another basis (a raw-byte verdict from before this change) is not comparable - STALE, fail closed
  [IO.File]::WriteAllText((Join-Path $cvG 'commodities.json'), ('{"commodities":[{"id":"milk","band":1}]}' + $cvLF), $cvNoBom)
  $cvOld = Get-Content -LiteralPath (Join-Path $cvOut 'chain-verdict.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $cvOld.PSObject.Properties.Remove('inputs_hash_basis')
  ($cvOld | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $cvOut 'chain-verdict.json') -Encoding UTF8
  $cv4 = Read-ChainVerdictStatus -Repo $cvTmp -OutDir $cvOut -Today $cvDay
  if ($cv4.status -eq 'STALE-INPUTS' -and -not $cv4.ship_ok -and $cv4.why -match 'basis') { Ok 'u051v: MUST FIRE - a verdict with no hash basis reads STALE-INPUTS (fail closed), never compared across bases' }
  else { Bad ('u051v: MUST FIRE - a basis-less verdict read ' + $cv4.status + ': ' + $cv4.why) }
  # capture-run books a STALE verdict as its own lane and pages it, and keeps guards-blocked for everything else
  $cvCr = Get-TcProductionText (Join-Path $root 'capture-run.ps1')
  $cvLib = Get-TcProductionText (Join-Path (Split-Path $root -Parent) 'lib\chain-verdict-lib.ps1')
  $cvLane = 'verdict' + '-stale'
  if ($cvCr -match 'Invoke-ChainVerdictWithheldLane -Verdict \$verdict' -and $cvLib -match ("-eq 'STALE-INPUTS'\)\s*\{\s*Add-FailedLane '" + $cvLane + "'") -and $cvLib -match ("Set-FailedLanePaged '" + $cvLane + "'") -and $cvLib -match "\}\s*else\s*\{\s*Add-FailedLane 'guards-blocked'") {
    Ok 'u051v: capture-run books STALE-INPUTS as lane verdict-stale (Invoke-ChainVerdictWithheldLane), pages it as itself, and keeps guards-blocked for a blocked board'
  } else { Bad 'u051v: capture-run no longer books a STALE-INPUTS withhold as verdict-stale - RUN RECORD names the wrong cause again' }
} catch { Bad ('u051v: the chain-verdict fixture threw: ' + $_.Exception.Message) }
finally { if (Test-Path -LiteralPath $cvTmp) { Remove-Item -LiteralPath $cvTmp -Recurse -Force -ErrorAction SilentlyContinue } }
} # u051v-chain-verdict-hashes-content
