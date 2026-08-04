<#
  send-friday-email.ps1 - Puts the built Friday email into Ghost.

  DEFAULTS TO A DRAFT. An email cannot be recalled, so this script will not send one unless you pass
  -Send explicitly. Without it you get an email-only draft in Ghost that you can preview, send a test
  of, and publish by hand. That is the right default for a weekly send whose whole job is to build
  trust with a list that took a month to collect.

  The post is EMAIL-ONLY (email_only=true). It deliberately does NOT become a page on the site: 52
  near-identical "grocery prices, week of X" posts a year is exactly the thin-content pattern that got
  475 URLs left uncrawled by Google in the first place (see lib\trend-keep.ps1).

  ONCE PER WEEK. A stamp file records the week_of already sent, so a double-run - a retried scheduled
  task, a manual run after the automation - cannot mail the list twice. -Force overrides.

  Usage:
    powershell -File send-friday-email.ps1              # build + create draft (safe)
    powershell -File send-friday-email.ps1 -Send        # build + actually mail the list
#>
param([switch]$Send, [switch]$Force, [switch]$SkipBuild)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here '..\lib\ghost-lib.ps1')

$apiUrl     = 'https://map-to-success.ghost.io'
$newsletter = 'default-newsletter'          # "Thrifty Crew" - the one free signups auto-join
$OutDir     = Join-Path $here 'out'
$htmlFile   = Join-Path $OutDir 'friday-email.html'
$metaFile   = Join-Path $OutDir 'friday-email.json'
$stampFile  = Join-Path $OutDir 'friday-email.stamp'

if (-not $SkipBuild) {
  & powershell -ExecutionPolicy Bypass -File (Join-Path $here 'build-friday-email.ps1') | ForEach-Object { Write-Host ('  ' + $_) }
  if ($LASTEXITCODE -ne 0) { throw "build-friday-email.ps1 failed (rc=$LASTEXITCODE) - nothing sent." }
}
if (-not (Test-Path $htmlFile)) { throw "missing $htmlFile" }

$meta = Get-Content $metaFile -Raw | ConvertFrom-Json
$html = [IO.File]::ReadAllText($htmlFile, [Text.Encoding]::UTF8)
if ($html.Length -lt 400) { throw "built email is only $($html.Length) chars - refusing to mail a stub." }

# A week with no staples priced is a pipeline failure, not a quiet week. Do not mail it.
if ([int]$meta.staples -eq 0) { throw "the staples table came out empty - that is a board problem, not a slow news week. Nothing sent." }

$week = [string]$meta.week
$sentWeek = ''
if (Test-Path $stampFile) { $sentWeek = (Get-Content $stampFile -Raw).Trim() }
if ($Send -and ($sentWeek -eq $week) -and -not $Force) {
  Write-Host ("already sent for week {0} - nothing to do (use -Force to override)" -f $week) -ForegroundColor Yellow
  exit 0
}

$key = Get-GhostKey -Root (Split-Path $here -Parent)
$jwt = Get-GhostJWT -Key $key
$h   = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0'; 'Content-Type' = 'application/json' }

$title  = [string]$meta.subject
$lex    = Get-GhostLexical -Html $html
$status = if ($Send) { 'published' } else { 'draft' }

$post = [ordered]@{
  title      = $title
  lexical    = $lex
  status     = $status
  email_only = $true
  # MUST be set explicitly. The site's default post visibility is "paid", and a Friday email created
  # without this went out flagged paid - i.e. the free weekly email promised on the board would have
  # reached the 2 paying members and gated everyone else. The whole point of this send is the free list.
  visibility = 'public'
  tags       = @(@{ name = '#friday-email' })   # internal tag: keeps these out of every public list
}
$body = ConvertTo-Json @{ posts = @($post) } -Depth 14
$bytes = [Text.Encoding]::UTF8.GetBytes($body)

# ?newsletter= is what turns a publish into a send. It is only meaningful when status=published, so a
# draft run carries it harmlessly and mails nobody.
$uri = "$apiUrl/ghost/api/admin/posts/?newsletter=$newsletter&email_segment=all"
$saved = (Invoke-GhostApi -Method POST -Uri $uri -Headers $h -Body $bytes -TimeoutSec 60).posts[0]

if ($Send) {
  [IO.File]::WriteAllText($stampFile, $week, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ("SENT  week={0}  subject: {1}" -f $week, $title) -ForegroundColor Green
  Write-Host ("  email_only={0}  status={1}  id={2}" -f $saved.email_only, $saved.status, $saved.id)
} else {
  Write-Host ("DRAFT created (nothing mailed). Review it in Ghost, then hit Publish, or re-run with -Send." -f $null) -ForegroundColor Cyan
  Write-Host ("  subject : {0}" -f $title)
  Write-Host ("  week={0}  staples={1}  drops={2}  records={3}" -f $week, $meta.staples, $meta.drops, $meta.records)
  Write-Host ("  edit    : {0}/ghost/#/editor/post/{1}" -f $apiUrl, $saved.id)
}
