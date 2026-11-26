# Fetches market data for Samsung Electronics (005930) and writes data/live.json and data/base.json.
# Runs on GitHub Actions (pwsh 7) and locally on Windows PowerShell 5.1.
# ASCII-only on purpose: Windows PowerShell 5.1 misreads non-ASCII literals in BOM-less scripts.
# Every section is independent: if one source fails, the previous value for that section is kept.

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$root = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $root 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Force $dataDir | Out-Null }
$livePath = Join-Path $dataDir 'live.json'
$basePath = Join-Path $dataDir 'base.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$kst = [TimeSpan]::FromHours(9)
$errors = New-Object System.Collections.ArrayList

function Get-Text([string]$url) {
  $last = $null
  for ($i = 0; $i -lt 3; $i++) {
    try {
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 25 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'; 'Accept' = 'application/json,text/plain,*/*' }
      $ms = $r.RawContentStream
      return $utf8.GetString($ms.ToArray())
    } catch { $last = $_; Start-Sleep -Seconds (2 * ($i + 1)) }
  }
  throw $last
}
function Get-Json([string]$url) { return (Get-Text $url) | ConvertFrom-Json }
# PowerShell 7 turns ISO date strings into DateTime objects when parsing JSON (5.1 does not),
# which loses the UTC offset. Timestamps are therefore read from the raw text.
function Get-RawField([string]$text, [string]$name) {
  $m = [regex]::Match($text, '"' + $name + '"\s*:\s*"([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

# "171,800" / "+6,534,711" / "45.84%" / "-" -> number or $null
function To-Num($v) {
  if ($null -eq $v) { return $null }
  $s = ([string]$v).Trim()
  $s = $s -replace '[^0-9eE\.\-]', ''
  if ($s -eq '' -or $s -eq '-' -or $s -eq '.') { return $null }
  $d = 0.0
  if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d)) {
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
    return $d
  }
  return $null
}
# Signed change: magnitude from the value, direction from the RISING/FALLING flag when present.
function To-Signed($v, $dirName) {
  $n = To-Num $v
  if ($null -eq $n) { return $null }
  if ($dirName -eq 'FALLING' -or $dirName -eq 'LOWER_LIMIT') { return -[Math]::Abs($n) }
  if ($dirName -eq 'RISING' -or $dirName -eq 'UPPER_LIMIT') { return [Math]::Abs($n) }
  return $n
}
function Read-Prev([string]$path) {
  if (Test-Path $path) { try { return [System.IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json } catch { return $null } }
  return $null
}
function Get-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}
function Kst-Date([long]$unix) { return [int]([DateTimeOffset]::FromUnixTimeSeconds($unix).ToOffset($kst).ToString('yyyyMMdd')) }

$prevLive = Read-Prev $livePath
$prevBase = Read-Prev $basePath
$nowIso = [DateTimeOffset]::UtcNow.ToOffset($kst).ToString('yyyy-MM-ddTHH:mm:sszzz')

# ---------------------------------------------------------------- quote (required)
$quote = $null
try {
  $pollText = Get-Text 'https://polling.finance.naver.com/api/realtime/domestic/stock/005930'
  $p = ($pollText | ConvertFrom-Json).datas[0]
  $price = To-Num $p.closePriceRaw
  if ($null -eq $price) { $price = To-Num $p.closePrice }
  $chg = To-Signed $p.compareToPreviousClosePrice $p.compareToPreviousPrice.name
  $pct = To-Signed $p.fluctuationsRatio $p.compareToPreviousPrice.name
  if ($null -eq $price -or $price -le 0) { throw 'bad price' }
  $quote = [ordered]@{
    price = $price; change = $chg; changePct = $pct
    prevClose = $(if ($null -ne $chg) { $price - $chg } else { $null })
    open = To-Num $p.openPrice; high = To-Num $p.highPrice; low = To-Num $p.lowPrice
    volume = To-Num $p.accumulatedTradingVolume
    marketCap = To-Num $p.marketValueFullRaw
    marketStatus = [string]$p.marketStatus
    session = [string]$p.marketSessionType
    tradedAt = (Get-RawField $pollText 'localTradedAt')
    source = 'naver'
  }
} catch { [void]$errors.Add("quote-naver: $($_.Exception.Message)") }

if ($null -eq $quote) {
  try {
    $m = (Get-Json 'https://query1.finance.yahoo.com/v8/finance/chart/005930.KS?range=5d&interval=1d').chart.result[0]
    $cl = @($m.indicators.quote[0].close | Where-Object { $null -ne $_ })
    $price = [double]$m.meta.regularMarketPrice
    if ($price -le 0) { throw 'bad price' }
    $prevC = $null
    if ($cl.Count -ge 2) { $prevC = [double]$cl[$cl.Count - 2] }
    $quote = [ordered]@{
      price = $price
      change = $(if ($null -ne $prevC) { $price - $prevC } else { $null })
      changePct = $(if ($null -ne $prevC -and $prevC -gt 0) { [Math]::Round(($price / $prevC - 1) * 100, 2) } else { $null })
      prevClose = $prevC
      open = $null; high = To-Num $m.meta.regularMarketDayHigh; low = To-Num $m.meta.regularMarketDayLow
      volume = To-Num $m.meta.regularMarketVolume; marketCap = $null
      marketStatus = ''; session = ''
      tradedAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$m.meta.regularMarketTime).ToOffset($kst).ToString('yyyy-MM-ddTHH:mm:sszzz')
      source = 'yahoo'
    }
  } catch { [void]$errors.Add("quote-yahoo: $($_.Exception.Message)") }
}

if ($null -eq $quote) {
  Write-Host "No quote from any source; keeping previous files. Errors: $($errors -join ' | ')"
  exit 0
}

# ---------------------------------------------------------------- stats
$stats = Get-Prop $prevLive 'stats'
try {
  $integ = Get-Json 'https://m.stock.naver.com/api/stock/005930/integration'
  $s = [ordered]@{}
  foreach ($it in $integ.totalInfos) {
    $s[[string]$it.code] = [ordered]@{ v = To-Num $it.value; asOf = [string](Get-Prop $it 'valueDesc') }
  }
  if ($s.Count -lt 5) { throw 'too few stats' }
  $stats = $s
} catch { [void]$errors.Add("stats: $($_.Exception.Message)") }

# ---------------------------------------------------------------- investor flows (last 20 sessions)
$flows = Get-Prop $prevLive 'flows'
try {
  $tr = Get-Json 'https://m.stock.naver.com/api/stock/005930/trend?pageSize=20'
  $list = New-Object System.Collections.ArrayList
  foreach ($d in $tr) {
    $dn = To-Num $d.bizdate
    if ($null -eq $dn) { continue }
    [void]$list.Add([ordered]@{
      d = [int]$dn
      f = To-Num $d.foreignerPureBuyQuant
      o = To-Num $d.organPureBuyQuant
      i = To-Num $d.individualPureBuyQuant
      fr = To-Num $d.foreignerHoldRatio
    })
  }
  if ($list.Count -eq 0) { throw 'empty' }
  $flows = @($list.ToArray())
} catch { [void]$errors.Add("flows: $($_.Exception.Message)") }

# ---------------------------------------------------------------- peers
function Get-Peer([string]$url, [switch]$Wrapped) {
  $peerText = Get-Text $url
  $j = $peerText | ConvertFrom-Json
  if ($Wrapped) { $j = $j.result }
  $dir = $null
  $cp = Get-Prop $j 'compareToPreviousPrice'
  if ($null -ne $cp) { $dir = [string]$cp.name }
  $ft = Get-Prop $j 'fluctuationsType'
  if ($null -ne $ft) { $dir = [string]$ft.name }
  $chgRaw = Get-Prop $j 'compareToPreviousClosePrice'
  if ($null -eq $chgRaw) { $chgRaw = Get-Prop $j 'fluctuations' }
  $px = To-Num $j.closePrice
  if ($null -eq $px -or $px -le 0) { throw 'bad peer price' }
  return [ordered]@{
    price = $px
    change = To-Signed $chgRaw $dir
    changePct = To-Signed $j.fluctuationsRatio $dir
    at = (Get-RawField $peerText 'localTradedAt')
  }
}
$peers = [ordered]@{}
$peerDefs = @(
  @{ k = 'kospi'; u = 'https://m.stock.naver.com/api/index/KOSPI/basic'; w = $false },
  @{ k = 'hynix'; u = 'https://m.stock.naver.com/api/stock/000660/basic'; w = $false },
  @{ k = 'micron'; u = 'https://api.stock.naver.com/stock/MU.O/basic'; w = $false },
  @{ k = 'sox'; u = 'https://api.stock.naver.com/index/.SOX/basic'; w = $false },
  @{ k = 'nvidia'; u = 'https://api.stock.naver.com/stock/NVDA.O/basic'; w = $false },
  @{ k = 'tsmc'; u = 'https://api.stock.naver.com/stock/TSM/basic'; w = $false },
  @{ k = 'sandisk'; u = 'https://api.stock.naver.com/stock/SNDK.O/basic'; w = $false },
  @{ k = 'usdkrw'; u = 'https://m.stock.naver.com/front-api/marketIndex/productDetail?category=exchange&reutersCode=FX_USDKRW'; w = $true }
)
foreach ($pd in $peerDefs) {
  try {
    if ($pd.w) { $peers[$pd.k] = Get-Peer $pd.u -Wrapped } else { $peers[$pd.k] = Get-Peer $pd.u }
  } catch {
    [void]$errors.Add("peer-$($pd.k): $($_.Exception.Message)")
    $old = Get-Prop (Get-Prop $prevLive 'peers') $pd.k
    if ($null -ne $old) { $peers[$pd.k] = $old }
  }
}

$live = [ordered]@{
  schema = 1
  updatedAt = $nowIso
  quote = $quote
  stats = $stats
  flows = $flows
  peers = $peers
  errors = @($errors.ToArray())
}
[System.IO.File]::WriteAllText($livePath, ($live | ConvertTo-Json -Depth 8 -Compress), $utf8)
Write-Host "live.json written: price=$($quote.price) source=$($quote.source) errors=$($errors.Count)"

# ---------------------------------------------------------------- base (history, dividends, financials)
# History excludes the current trading day so the file only changes once per day; the app appends the live price.
$baseErrors = New-Object System.Collections.ArrayList
$todayKst = [int]([DateTimeOffset]::UtcNow.ToOffset($kst).ToString('yyyyMMdd'))

function Get-Series([string]$symbol, [string]$range, [string]$interval, [switch]$WithDividends) {
  $u = "https://query1.finance.yahoo.com/v8/finance/chart/$([uri]::EscapeDataString($symbol))?range=$range&interval=$interval"
  if ($WithDividends) { $u += '&events=div' }
  $res = (Get-Json $u).chart.result[0]
  $ts = @($res.timestamp); $cl = @($res.indicators.quote[0].close)
  $map = [ordered]@{}
  for ($i = 0; $i -lt $ts.Count; $i++) {
    if ($null -eq $cl[$i]) { continue }
    $d = Kst-Date ([long]$ts[$i])
    if ($d -ge $todayKst) { continue }
    $map[[string]$d] = [Math]::Round([double]$cl[$i], 2)
  }
  $t = New-Object System.Collections.ArrayList; $c = New-Object System.Collections.ArrayList
  foreach ($k in $map.Keys) { [void]$t.Add([int]$k); [void]$c.Add($map[$k]) }
  if ($t.Count -lt 10) { throw "series too short for $symbol" }
  $out = [ordered]@{ t = @($t.ToArray()); c = @($c.ToArray()) }
  if ($WithDividends) {
    $dv = New-Object System.Collections.ArrayList
    $ev = Get-Prop $res 'events'
    $dd = Get-Prop $ev 'dividends'
    if ($null -ne $dd) {
      foreach ($pp in $dd.PSObject.Properties) {
        $amt = To-Num $pp.Value.amount
        if ($null -eq $amt -or $amt -le 0) { continue }
        [void]$dv.Add([ordered]@{ d = (Kst-Date ([long]$pp.Value.date)); a = $amt })
      }
    }
    $out['div'] = @($dv.ToArray() | Sort-Object { $_.d })
  }
  return $out
}

function Get-Fin([string]$period) {
  $f = (Get-Json "https://m.stock.naver.com/api/stock/005930/finance/$period").financeInfo
  $periods = @($f.trTitleList | Sort-Object { [string]$_.key })
  $pl = New-Object System.Collections.ArrayList
  foreach ($pp in $periods) { [void]$pl.Add([ordered]@{ key = [string]$pp.key; est = ([string]$pp.isConsensus -eq 'Y') }) }
  $rows = [ordered]@{}
  foreach ($row in $f.rowList) {
    $vals = New-Object System.Collections.ArrayList
    foreach ($pp in $periods) {
      $cell = Get-Prop $row.columns ([string]$pp.key)
      [void]$vals.Add($(if ($null -ne $cell) { To-Num $cell.value } else { $null }))
    }
    $rows[[string]$row.title] = @($vals.ToArray())
  }
  if ($pl.Count -lt 2 -or $rows.Count -lt 3) { throw "fin $period too small" }
  return [ordered]@{ periods = @($pl.ToArray()); rows = $rows }
}

$daily = Get-Prop $prevBase 'daily'; $weekly = Get-Prop $prevBase 'weekly'; $kospiW = Get-Prop $prevBase 'kospiWeekly'
$divs = Get-Prop $prevBase 'dividends'; $finQ = Get-Prop $prevBase 'finQuarter'; $finA = Get-Prop $prevBase 'finAnnual'

try { $daily = Get-Series '005930.KS' '2y' '1d' } catch { [void]$baseErrors.Add("daily: $($_.Exception.Message)") }
try {
  $w = Get-Series '005930.KS' '10y' '1wk' -WithDividends
  $weekly = [ordered]@{ t = $w.t; c = $w.c }
  if (@($w.div).Count -gt 0) { $divs = @($w.div) }
} catch { [void]$baseErrors.Add("weekly: $($_.Exception.Message)") }
try { $kospiW = Get-Series '^KS11' '10y' '1wk' } catch { [void]$baseErrors.Add("kospiWeekly: $($_.Exception.Message)") }
try { $finQ = Get-Fin 'quarter' } catch { [void]$baseErrors.Add("finQuarter: $($_.Exception.Message)") }
try { $finA = Get-Fin 'annual' } catch { [void]$baseErrors.Add("finAnnual: $($_.Exception.Message)") }

# ---- how Samsung moved on the Korean session after a big US move (last ~1 year)
# US date d closes at about 06:00 KST on d+1, so the reaction day is the first KRX session dated after d.
function Get-UsReturns([string]$symbol) {
  $res = (Get-Json "https://query1.finance.yahoo.com/v8/finance/chart/$([uri]::EscapeDataString($symbol))?range=1y&interval=1d").chart.result[0]
  $off = [TimeSpan]::FromSeconds([double]$res.meta.gmtoffset)
  $ts = @($res.timestamp); $cl = @($res.indicators.quote[0].close)
  $out = New-Object System.Collections.ArrayList
  $prev = $null
  for ($i = 0; $i -lt $ts.Count; $i++) {
    if ($null -eq $cl[$i]) { continue }
    $c = [double]$cl[$i]
    if ($null -ne $prev -and $prev -gt 0) {
      $d = [int]([DateTimeOffset]::FromUnixTimeSeconds([long]$ts[$i]).ToOffset($off).ToString('yyyyMMdd'))
      [void]$out.Add(@{ d = $d; r = ($c / $prev - 1) * 100 })
    }
    $prev = $c
  }
  return ,$out
}
function Get-Reaction($usRets, $kr, [double]$thr) {
  # $kr: @{ t = int[]; c = double[] } daily Samsung closes
  $n = 0; $sx = 0.0; $sy = 0.0; $sxx = 0.0; $syy = 0.0; $sxy = 0.0
  $upN = 0; $upSum = 0.0; $upHit = 0; $dnN = 0; $dnSum = 0.0; $dnHit = 0
  $kt = @($kr.t); $kc = @($kr.c)
  foreach ($u in $usRets) {
    $idx = -1
    for ($j = 1; $j -lt $kt.Count; $j++) { if ([int]$kt[$j] -gt $u.d) { $idx = $j; break } }
    if ($idx -lt 1) { continue }
    if (([int]$kt[$idx] - $u.d) -gt 5 -and ([int]$kt[$idx] % 100) -gt 6) { continue }   # skip long gaps (holidays)
    $y = ([double]$kc[$idx] / [double]$kc[$idx - 1] - 1) * 100
    $x = [double]$u.r
    $n++; $sx += $x; $sy += $y; $sxx += $x * $x; $syy += $y * $y; $sxy += $x * $y
    if ($x -ge $thr) { $upN++; $upSum += $y; if ($y -gt 0) { $upHit++ } }
    if ($x -le -$thr) { $dnN++; $dnSum += $y; if ($y -lt 0) { $dnHit++ } }
  }
  if ($n -lt 30) { throw 'too few paired days' }
  $den = [Math]::Sqrt(($n * $sxx - $sx * $sx) * ($n * $syy - $sy * $sy))
  $corr = $(if ($den -gt 0) { ($n * $sxy - $sx * $sy) / $den } else { 0 })
  return [ordered]@{
    n = $n; thr = $thr; corr = [Math]::Round($corr, 2)
    upN = $upN; upAvg = $(if ($upN -gt 0) { [Math]::Round($upSum / $upN, 2) } else { $null }); upHit = $upHit
    dnN = $dnN; dnAvg = $(if ($dnN -gt 0) { [Math]::Round($dnSum / $dnN, 2) } else { $null }); dnHit = $dnHit
  }
}
$react = Get-Prop $prevBase 'react'
try {
  if ($null -eq $daily) { throw 'no daily series' }
  $r = [ordered]@{}
  $r['micron'] = Get-Reaction (Get-UsReturns 'MU') $daily 3
  $r['sox'] = Get-Reaction (Get-UsReturns '^SOX') $daily 2
  $react = $r
} catch { [void]$baseErrors.Add("react: $($_.Exception.Message)") }

$baseBody = [ordered]@{
  schema = 1
  daily = $daily; weekly = $weekly; kospiWeekly = $kospiW
  dividends = $divs; finQuarter = $finQ; finAnnual = $finA; react = $react
}
$bodyJson = $baseBody | ConvertTo-Json -Depth 8 -Compress
$prevBody = ''
if ($null -ne $prevBase) {
  $pb = [ordered]@{
    schema = 1
    daily = $prevBase.daily; weekly = $prevBase.weekly; kospiWeekly = $prevBase.kospiWeekly
    dividends = $prevBase.dividends; finQuarter = $prevBase.finQuarter; finAnnual = $prevBase.finAnnual; react = (Get-Prop $prevBase 'react')
  }
  $prevBody = $pb | ConvertTo-Json -Depth 8 -Compress
}
if ($bodyJson -ne $prevBody) {
  $baseOut = [ordered]@{
    schema = 1; updatedAt = $nowIso
    daily = $daily; weekly = $weekly; kospiWeekly = $kospiW
    dividends = $divs; finQuarter = $finQ; finAnnual = $finA; react = $react
  }
  [System.IO.File]::WriteAllText($basePath, ($baseOut | ConvertTo-Json -Depth 8 -Compress), $utf8)
  Write-Host "base.json written. errors=$($baseErrors.Count)"
} else {
  Write-Host "base.json unchanged. errors=$($baseErrors.Count)"
}
if ($errors.Count -gt 0) { Write-Host ("live errors: " + ($errors -join ' | ')) }
if ($baseErrors.Count -gt 0) { Write-Host ("base errors: " + ($baseErrors -join ' | ')) }
exit 0
