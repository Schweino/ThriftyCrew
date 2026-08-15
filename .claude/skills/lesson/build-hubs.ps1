<#
  build-hubs.ps1  -  Rebuilds the 6 public topic-hub pages from the lesson lists below.
  To add a NEW lesson to a hub: add its slug to the matching hub's `lessons` array, then
  run this script. It is idempotent (upserts each page), so re-running is safe.
  Hubs cluster the 52 lessons by topic and are linked from the /financial-lessons/ intro.
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\ghost-config.ps1"   # -> $adminKey, $apiUrl
function New-GhostJWT { param($key)
  $p=$key -split ':'; $id=$p[0]; $secretHex=$p[1]
  $sb=New-Object byte[] ($secretHex.Length/2)
  for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
$jwt = New-GhostJWT $adminKey
$posts = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/?limit=all&filter=tag:financial-lessons&fields=slug,title,visibility&formats=" -Headers @{ Authorization="Ghost $jwt"; 'Accept-Version'='v5.0' }).posts
$lookup = @{}
$vislookup = @{}
foreach ($p in $posts) { $lookup[$p.slug] = $p.title; $vislookup[$p.slug] = $p.visibility }

# ==== HUB DEFINITIONS - add a new lesson's slug to the right `lessons` array, then re-run ====
$hubs = @(
  [ordered]@{ slug='money-mindset-and-habits'; title='Money Mindset & Habits';
    metaTitle='Money Mindset & Habits: Build the Foundation';
    metaDesc='Money skill is really habit and mindset in disguise. The lessons that build the foundation: future thinking, spending psychology, and the small habits that compound.';
    lead='Money skill is really habit and mindset wearing a disguise.';
    body='Before budgets and index funds, there is the quieter stuff: how you picture the future, why you buy what you buy, and the small daily habits that compound into a whole different life. This track builds that foundation.';
    lessons=@('week-1-future-you-is-a-real-person','week-2-the-compounding-secret','week-3-win-the-first-five-minutes','week-4-the-gap-is-the-score','week-14-no-one-is-coming-to-save-you-and-thats-good-news','week-40-want-less-win-more','week-44-what-are-you-really-buying','week-48-the-few-expensive-mistakes','week-43-the-highlight-reel','week-49-taming-the-need-to-fit-in','week-47-choose-your-crowd','week-45-borrow-other-peoples-hindsight','week-46-how-to-spot-good-advice-from-bad','week-12-talking-about-money-without-fighting','week-51-your-kids-first-five-year-plan','week-52-a-letter-to-future-you') }
  [ordered]@{ slug='budgeting-and-spending'; title='Budgeting & Spending';
    metaTitle='Budgeting & Spending: A Budget That Sticks';
    metaDesc='A budget is not about spending less, it is about knowing where it goes. Lessons on your first budget, tracking spending, needs vs wants, and beating lifestyle creep.';
    lead='A budget is not about spending less &mdash; it is about knowing where it goes.';
    body='The core skill of money is the gap between what comes in and what goes out. This track covers building a first budget, tracking where the money actually goes, telling needs from wants, and keeping lifestyle creep from eating every raise.';
    lessons=@('week-5-needs-first-then-wants','week-6-your-kids-first-budget','week-7-where-does-the-money-go','week-35-what-affordable-really-means','week-41-lifestyle-creep','week-42-the-30-breathing-room-rule','save-money-on-vacation') }
  [ordered]@{ slug='saving-and-banking'; title='Saving & Banking';
    metaTitle='Saving & Banking: Pay Yourself First';
    metaDesc='Saving is a habit before it is an amount. Lessons on pay-yourself-first, opening a real account, earning vs allowance, and the money case for generosity.';
    lead='Pay yourself first &mdash; then make it automatic.';
    body='Saving is a habit long before it is an amount. This track covers the pay-yourself-first rule, opening a real bank account, the difference between earning and an allowance, and the surprising money case for giving.';
    lessons=@('week-9-pay-yourself-first','week-10-opening-the-first-account','week-11-allowance-vs-earning','week-50-the-gift-of-giving') }
  [ordered]@{ slug='earning-and-first-jobs'; title='Earning & First Jobs';
    metaTitle='Earning & First Jobs: Land It, Build a Reputation';
    metaDesc='Money gets easier when you are good at making it. Lessons on finding work you care about, landing and nailing a first job, and building skills and a reputation that follow you.';
    lead='The first paycheck matters less than the person you become earning it.';
    body='Money gets a lot easier when you are good at making it. This track covers finding work you actually care about, landing and nailing a first job, building skills that beat luck, and the reputation that walks into the room before you do.';
    lessons=@('week-8-the-first-job-conversation','week-16-find-the-thing-that-pulls-at-you','week-15-skills-beat-luck','week-17-the-internet-is-a-tool-not-a-trap','week-18-apply-it-or-lose-it','week-19-do-the-work-before-youre-paid-for-it','week-20-your-reputation-travels-faster-than-you-do','week-21-show-up-on-time-every-time','week-22-how-to-get-a-first-job','week-23-the-first-interview','week-24-be-the-employee-they-brag-about','week-25-references-are-currency') }
  [ordered]@{ slug='investing-basics'; title='Investing Basics';
    metaTitle='Investing Basics: Index Funds, Compounding & Starting Early';
    metaDesc='You do not need to be rich or clever to invest well, you need time and a low-cost index fund. Lessons that make compounding, index funds, and 401(k) matches simple to use.';
    lead='The boring strategy quietly beats almost everyone.';
    body='You do not need to be rich or clever to invest well &mdash; you need time and a low-cost index fund. This track makes compounding, index funds, custodial accounts, and the 401(k) match simple enough to actually use.';
    lessons=@('free-basics-of-investing','week-27-time-is-your-superpower','week-28-meet-compound-interest-hands-on','week-29-the-custodial-account-conversation','week-30-boring-wins-index-funds-101','week-31-the-401-k-and-free-money','week-39-quarter-review-money-that-grows') }
  [ordered]@{ slug='debt-and-credit'; title='Debt & Credit';
    metaTitle='Debt & Credit: How Credit Cards, Scores & Loans Really Work';
    metaDesc='Debt is not always failure, but it always needs a plan out. Lessons that decode credit cards, credit scores, buy-now-pay-later, good vs bad debt, and student loans.';
    lead='Debt is not always failure &mdash; but it always needs a plan out.';
    body='Credit is a tool that can quietly work for you or against you. This track decodes credit cards, credit scores, buy-now-pay-later traps, good vs. bad debt, student loans, and how to turn great credit into a real advantage.';
    lessons=@('week-33-how-a-credit-card-actually-tricks-you','week-38-credit-scores-explained-simply','week-34-buy-now-pay-later-is-the-same-trap','week-32-the-trap-that-looks-like-help','week-36-good-debt-bad-debt-and-the-exit-plan','week-37-student-loans-without-the-panic','bonus-lesson-turn-great-credit-into-free-flights') }
)

function Upsert-Page($slug, $title, $html, $metaTitle, $metaDesc) {
  $jwt = New-GhostJWT $adminKey
  $existing = $null
  try { $existing = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/pages/slug/$slug/?fields=id,updated_at" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}).pages[0] } catch {}
  $lexObj = @{ root = [ordered]@{ children=@([ordered]@{ type='html'; version=1; html=[string]$html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
  $lex = ConvertTo-Json $lexObj -Depth 12 -Compress
  $pageObj = [ordered]@{ title=$title; slug=$slug; lexical=$lex; status='published'; meta_title=$metaTitle; meta_description=$metaDesc; og_title=$metaTitle; og_description=$metaDesc; twitter_title=$metaTitle; twitter_description=$metaDesc }
  if ($existing) { $pageObj.updated_at=$existing.updated_at; $method='Put'; $uri="$apiUrl/ghost/api/admin/pages/$($existing.id)/" }
  else { $method='Post'; $uri="$apiUrl/ghost/api/admin/pages/" }
  $payload = @{ pages=@($pageObj) }
  $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 16))
  $jwt2 = New-GhostJWT $adminKey
  Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $bytes | Out-Null
  return ($existing -ne $null)
}

$dollar = [char]0x24
foreach ($hub in $hubs) {
  $lis = ""
  foreach ($ls in $hub.lessons) {
    $t = $lookup[$ls]; if (-not $t) { Write-Host "  MISSING (not on site yet): $ls" -ForegroundColor Yellow; continue }
    $free = ""
    if ($vislookup[$ls] -eq 'public') { $free = ' <span style="color:#8a6d1f;font-weight:700;font-size:.85em;">&middot; free</span>' }
    $disp = ($t -replace '\s*\(Free!\)\s*','')
    $lis += "<li style=""margin-bottom:.5rem;""><a href=""/$ls/"">$disp</a>$free</li>"
  }
  $others = (@($hubs | Where-Object { $_.slug -ne $hub.slug } | ForEach-Object { "<a href=""/$($_.slug)/"">$($_.title)</a>" }) -join ' &middot; ')
  $html = "<div style=""max-width:720px;margin:0 auto;""><div class=""mts-tagintro""><div class=""mts-tagintro-inner""><p><strong>$($hub.lead)</strong> $($hub.body)</p></div></div><h2 style=""font-family:Georgia,'Times New Roman',serif;color:#16263F;"">The lessons in this track</h2><ul style=""line-height:1.6;font-size:1.65rem;padding-left:1.4rem;"">$lis</ul><div class=""mts-cta""><p class=""mts-cta-lead"">Unlock every lesson for ${dollar}10 a year.</p><p>All 52 weeks and every recipe &mdash; and it pays for itself the first grocery run. About ${dollar}0.83 a month, cancel anytime.</p><a class=""mts-btn mts-btn-gold"" href=""#/portal/signup"">Get ahead now &rarr;</a></div><p style=""text-align:center;font-size:1.5rem;margin-top:2.6rem;color:#4a5568;"">More tracks: $others</p></div>"
  $wasUpdate = Upsert-Page $hub.slug $hub.title $html $hub.metaTitle $hub.metaDesc
  $verb = if ($wasUpdate) { "updated" } else { "created" }
  Write-Host ("{0}: /{1}/  ({2} lessons)" -f $verb, $hub.slug, $hub.lessons.Count) -ForegroundColor Green
}
Write-Host "HUBS DONE." -ForegroundColor Cyan
