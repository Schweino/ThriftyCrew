<#
  add-serving-scaler.ps1 - Injects the "Make it your size" serving-scaler widget into published recipe posts.

  For each published recipe in recipes-db.json: fetch the post by slug (Ghost Admin API), insert or replace
  the widget block (idempotent via SMP-SCALER marker comments), PUT the post back. The widget embeds the
  recipe's ingredient data (item/grams/buy), base servings (14), and true batch cost; a stepper (2-42)
  scales quantities and cost linearly client-side with an honesty note. Updating a published post does NOT
  email members.

  Usage: powershell -File add-serving-scaler.ps1 -Slug fajita-chicken-rice-bowl   (pilot one)
         powershell -File add-serving-scaler.ps1 -All                             (all published)
#>
param([string]$Slug = "", [switch]$All)
$ErrorActionPreference = 'Stop'
# Ghost admin key: env var (GitHub Actions secret) first, then a gitignored local .ghostkey file, never source.
$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } elseif (Test-Path (Join-Path $PSScriptRoot '.ghostkey')) { (Get-Content (Join-Path $PSScriptRoot '.ghostkey') -Raw).Trim() } else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }
$apiUrl   = "https://map-to-success.ghost.io"

function New-GhostJWT {
  $id,$secret = $adminKey -split ':'
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $b64 = { param($b) [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $sb=New-Object byte[] ($secret.Length/2); for($i=0;$i -lt $sb.Length;$i++){$sb[$i]=[Convert]::ToByte($secret.Substring($i*2,2),16)}
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
function JsonEsc([string]$s) {
  $sb2 = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if ($ch -eq '\') { [void]$sb2.Append('\\') }
    elseif ($ch -eq '"') { [void]$sb2.Append('\"') }
    elseif ($c -lt 32) { switch ($c) { 10 { [void]$sb2.Append('\n') } 13 { [void]$sb2.Append('\r') } 9 { [void]$sb2.Append('\t') } default { [void]$sb2.Append('\u' + $c.ToString('x4')) } } }
    else { [void]$sb2.Append($ch) }
  }
  return $sb2.ToString()
}

$db = (Get-Content (Join-Path $PSScriptRoot 'recipes-db.json') -Raw | ConvertFrom-Json).recipes
$targets = if ($All) { @($db | Where-Object { "" + $_.published -match "^\d{4}" }) } else { @($db | Where-Object { $_.slug -eq $Slug }) }
if (-not $targets) { Write-Output "no matching recipes"; exit 1 }

# the widget's shared JS+CSS (identical in every post; script guards against double-init)
$widgetCore = @'
<style>.smp-sc{margin:0 0 2.4rem;padding:1.8rem 2rem;background:#F6F1E7;border:1px solid #e5dcc8;border-radius:12px}
.smp-sc h3{font-family:Georgia,serif;color:#16263F;font-size:2rem;margin:0 0 .4rem}
.smp-sc-sub{color:#64748b;font-size:1.35rem;margin:0 0 1.2rem}
.smp-sc-row{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:1.2rem}
.smp-sc-row b{color:#16263F;font-size:1.5rem}
.smp-sc-btn{width:40px;height:40px;border-radius:999px;border:2px solid #16263F;background:#fff;color:#16263F;font-size:1.8rem;font-weight:700;cursor:pointer;line-height:1}
.smp-sc-num{width:70px;text-align:center;font-size:1.7rem;font-weight:700;color:#16263F;border:1.5px solid #d8dee8;border-radius:8px;padding:6px 4px}
.smp-sc-cost{font-size:1.5rem;color:#16263F;margin:0 0 1rem}.smp-sc-cost b{color:#0c5c3b}
.smp-sc-list{margin:0;padding:0;list-style:none}
.smp-sc-list li{display:flex;justify-content:space-between;gap:14px;padding:.55rem 0;border-bottom:1px dotted #d8d0bc;font-size:1.42rem;color:#3a4658}
.smp-sc-list li span:last-child{white-space:nowrap;font-weight:600;color:#16263F}
.smp-sc-note{font-size:1.15rem;color:#8a94a6;margin:1.1rem 0 0;line-height:1.5}</style>
<script>
(function(){
if(window.__smpScaler)return; window.__smpScaler=1;
function fmtQty(v){ if(v>=10)return String(Math.round(v)); if(v>=1){var r=Math.round(v*4)/4; return (r%1===0)?String(r):r.toFixed(2).replace(/\.?0+$/,'');} return String(Math.round(v*100)/100); }
function scaleBuy(buy,f){ return buy.replace(/\d+(?:\.\d+)?/g,function(m){ return fmtQty(parseFloat(m)*f); }); }
function init(box){
  var data=JSON.parse(box.querySelector('.smp-sc-data').textContent);
  var num=box.querySelector('.smp-sc-num'), list=box.querySelector('.smp-sc-list'), cost=box.querySelector('.smp-sc-cost');
  function render(){
    var n=Math.max(2,Math.min(42,parseInt(num.value)||data.base)); num.value=n;
    var f=n/data.base, html='';
    data.ing.forEach(function(it){
      var amt=scaleBuy(it.buy,f)+(it.grams?' ('+Math.round(it.grams*f)+' g)':'');
      html+='<li><span>'+it.item+'</span><span>'+amt+'</span></li>';
    });
    list.innerHTML=html;
    var tot=data.cost*f;
    cost.innerHTML='Total for '+n+' servings: <b>$'+tot.toFixed(2)+'</b> (about $'+(tot/n).toFixed(2)+' a serving)';
  }
  box.querySelectorAll('.smp-sc-btn').forEach(function(b){ b.addEventListener('click',function(){ num.value=(parseInt(num.value)||data.base)+parseInt(b.getAttribute('data-d')); render(); }); });
  num.addEventListener('change',render);
  render();
}
function go(){ document.querySelectorAll('.smp-sc').forEach(init); }
if(document.readyState==='loading'){ document.addEventListener('DOMContentLoaded',go); } else { go(); }
})();
</script>
'@

$jwt = New-GhostJWT
$hdr = @{ Authorization = "Ghost $jwt" }
$done = 0; $skipped = 0; $failed = 0
foreach ($r in $targets) {
  try {
    if ($done % 20 -eq 0) { $jwt = New-GhostJWT; $hdr = @{ Authorization = "Ghost $jwt" } }   # tokens live 5 min
    $g = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$($r.slug)/?formats=html" -Headers $hdr
    $post = $g.posts[0]
    $html = [string]$post.html
    # per-recipe data JSON (item/grams/buy + base + true cost)
    $ings = @()
    foreach ($i in $r.ingredients) { $ings += ('{"item":"' + (JsonEsc ([string]$i.item)) + '","grams":' + [int]$i.grams + ',"buy":"' + (JsonEsc ([string]$i.buy)) + '"}') }
    $cost = if ($r.cost_batch_true) { [double]$r.cost_batch_true } else { [double]$r.cost_batch }
    $dataJson = '{"base":' + [int]$r.servings + ',"cost":' + ('{0:F2}' -f $cost) + ',"ing":[' + ($ings -join ',') + ']}'
    $widget = '<!--SMP-SCALER-->' + $widgetCore +
      '<div class="smp-sc"><h3>Make it your size</h3><p class="smp-sc-sub">This recipe is written for 14 servings. Change the number and every amount updates.</p>' +
      '<div class="smp-sc-row"><b>Servings:</b><button type="button" class="smp-sc-btn" data-d="-1">&minus;</button><input class="smp-sc-num" type="number" min="2" max="42" value="' + [int]$r.servings + '"><button type="button" class="smp-sc-btn" data-d="1">+</button></div>' +
      '<p class="smp-sc-cost"></p><ul class="smp-sc-list"></ul>' +
      '<p class="smp-sc-note">Costs scale proportionally and assume you use part of each package; your register total may differ. Per-serving macros do not change when you scale.</p>' +
      '<script type="application/json" class="smp-sc-data">' + $dataJson + '</script></div><!--/SMP-SCALER-->'
    # strip any prior widget, then prepend the fresh one
    $html = [regex]::Replace($html, '<!--SMP-SCALER-->[\s\S]*?<!--/SMP-SCALER-->', '')
    $html = $widget + $html
    # LEXICAL single html card, NOT ?source=html: the html-source path re-parses the content and strips
    # style/script/input tags (it destroyed the pilot post). The html card preserves everything verbatim.
    $lexObj = @{root=[ordered]@{children=@([ordered]@{type='html';version=1;html=$html});direction=$null;format='';indent=0;type='root';version=1}}
    $lex = ConvertTo-Json $lexObj -Depth 12 -Compress
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{posts=@(@{lexical=$lex;updated_at=$post.updated_at})} -Depth 6))
    $u = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Method Put -Headers $hdr -ContentType 'application/json' -Body $body
    $done++
    Write-Output ("OK  " + $r.slug)
  } catch { $failed++; Write-Output ("FAIL " + $r.slug + " : " + $_.Exception.Message) }
}
Write-Output ("scaler: " + $done + " updated, " + $failed + " failed")
