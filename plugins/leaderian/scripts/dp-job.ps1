<#
  dp-job.ps1 — 상세페이지 스튜디오 작업 스크립트 (Windows PowerShell 5.1 이상, 추가 설치 없음)
  서버 도구(dp_project_create · dp_render · dp_lint_copy)가 돌려준 명령을 그대로 실행합니다.
    init   : 새 상세페이지 작업 폴더 만들기
    render : page.html·theme.css·assets 를 올리고, 렌더 결과를 output\ 에 합친 뒤 자동검수 요약 출력
    lint   : 03_copy.md 카피 점검 결과 출력
    merge  : 마지막 전체 렌더를 통이미지(긴 JPG)로 합쳐 output\merged 에 받기
    catalog: 견본 묶음(완성 견본·컴포넌트·프리셋 미리보기)을 받아 Dir 에 풀기
  실행: powershell -NoProfile -ExecutionPolicy Bypass -File dp-job.ps1 render -Api <주소> -Ticket <작업표> -Dir <작업 폴더>
  이 파일은 UTF-8(BOM 포함)로 저장해야 한글이 깨지지 않습니다.
#>
param(
  [Parameter(Mandatory = $true, Position = 0)][ValidateSet('init', 'render', 'lint', 'merge', 'catalog')][string]$Command,
  [Parameter(Mandatory = $true)][string]$Api,
  [Parameter(Mandatory = $true)][string]$Ticket,
  [Parameter(Mandatory = $true)][string]$Dir
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

# PowerShell 5.1 의 curl 은 다른 명령의 별명이라, 윈도우 기본 curl.exe·tar.exe 를 경로로 부른다
$Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
foreach ($exe in @($Curl, $Tar)) { if (-not (Test-Path $exe)) { Write-Output "❌ $exe 가 없습니다. Windows 10 (1803) 이상이 필요해요."; exit 1 } }
$Api = $Api.TrimEnd('/')
$Dir = [IO.Path]::GetFullPath($Dir)
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('dp-job-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Tmp | Out-Null
$ImageRe = '^assets/[A-Za-z0-9._/-]+\.(png|jpe?g|webp|gif|svg|avif)$'
$AssetsMax = 30MB

function Stop-Work([string]$Message) {
  Write-Output "❌ $Message"
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  exit 1
}

# 서버 호출 → @{ code; text; map(key=value 줄) }
function Invoke-Api([string]$Method, [string]$Path, [string]$BodyFile, [string]$ContentType, [hashtable]$Headers) {
  $resp = Join-Path $Tmp 'resp.txt'
  $a = @('-sS', '-X', $Method, '-o', $resp, '-w', '%{http_code}')
  if ($ContentType) { $a += @('-H', "Content-Type: $ContentType") }
  if ($Headers) { foreach ($k in $Headers.Keys) { $a += @('-H', ($k + ': ' + $Headers[$k])) } }
  if ($BodyFile) { $a += @('--data-binary', "@$BodyFile") }
  $a += "$Api$Path"
  $code = & $Curl @a
  if ($LASTEXITCODE -ne 0) { Stop-Work "서버에 연결하지 못했어요 (curl $LASTEXITCODE). 인터넷 연결을 확인해 주세요." }
  $text = ''
  if (Test-Path $resp) { $text = [IO.File]::ReadAllText($resp, [Text.Encoding]::UTF8) }
  $map = @{}
  foreach ($line in ($text -split "`n")) { $i = $line.IndexOf('='); if ($i -gt 0) { $map[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() } }
  if ([int]$code -ge 400) { if ($map['error']) { Stop-Work $map['error'] } else { Stop-Work "서버 오류 ($code)" } }
  return @{ code = [int]$code; text = $text; map = $map }
}

function Get-Rel([string]$Full) { return $Full.Substring($Dir.Length).TrimStart('\').Replace('\', '/') }

# 렌더에 쓸 이미지 목록 (assets 아래 이미지 파일). 이름 규칙에 안 맞는 이미지가 있으면 멈춘다
function Get-AssetFiles {
  $assetsDir = Join-Path $Dir 'assets'
  if (-not (Test-Path $assetsDir)) { return @() }
  $ok = @(); $bad = @()
  foreach ($f in (Get-ChildItem -Recurse -File -Force $assetsDir | Sort-Object FullName)) {
    $rel = Get-Rel $f.FullName
    if ($f.Extension -notmatch '^\.(png|jpe?g|webp|gif|svg|avif)$') { continue }   # 이미지가 아니면 올리지 않음
    if ($rel -match $ImageRe) { $ok += $f } else { $bad += $rel }
  }
  if ($bad.Count) { Stop-Work ("이미지 파일 이름은 영문·숫자·하이픈(-)·밑줄(_)만 쓸 수 있어요. 이름을 바꾼 뒤 page.html 의 경로도 고쳐 주세요: " + ($bad -join ', ')) }
  return $ok
}

function Get-AssetsHash($Files) {
  if (-not $Files -or $Files.Count -eq 0) { return 'none' }
  $sb = New-Object Text.StringBuilder
  foreach ($f in $Files) { [void]$sb.Append((Get-Rel $f.FullName) + ' ' + (Get-FileHash -Algorithm SHA256 $f.FullName).Hash.ToLower() + "`n") }
  $sha = [Security.Cryptography.SHA256]::Create()
  return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString())) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Write-Preview([string]$OutDir) {
  $list = @(Get-ChildItem -File (Join-Path $OutDir '1000') -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object Name)
  $name = Split-Path $Dir -Leaf
  $items = ($list | ForEach-Object { "<div class=`"cap`">$($_.Name)</div><img src=`"1000/$($_.Name)`">" }) -join ''
  $html = "<!doctype html><meta charset=`"utf-8`"><title>미리보기 · $name</title><style>body{margin:0;background:#2b2b2b;font-family:sans-serif}main{width:500px;margin:0 auto}img{display:block;width:500px}.cap{color:#aaa;font-size:12px;padding:6px 0}</style><main>$items</main>"
  [IO.File]::WriteAllText((Join-Path $OutDir 'preview.html'), $html, (New-Object System.Text.UTF8Encoding $false))
  return $list.Count
}

# 작업이 끝날 때까지 기다린다 → 상태 (key=value)
function Wait-Done([string]$What) {
  $deadline = (Get-Date).AddMinutes(7)
  Start-Sleep -Seconds 4
  do {
    $st = Invoke-Api 'GET' "/jobs/status?t=$Ticket" $null $null $null
    $status = $st.map['status']
    if ($status -eq 'done' -or $status -eq 'failed') { break }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  if ($status -eq 'failed') { Stop-Work ($What + ' 실패: ' + $st.map['error']) }
  if ($status -ne 'done') { Stop-Work ($What + ' 시간이 너무 오래 걸려요. 잠시 뒤 다시 해 주세요.') }
  return $st
}

# 결과 묶음을 받아 임시 폴더에 푼다 → 그 폴더
function Get-Result([string]$Url) {
  $res = Join-Path $Tmp 'result.tgz'
  $code = & $Curl -sS -o $res -w '%{http_code}' $Url
  if ($LASTEXITCODE -ne 0 -or [int]$code -ne 200) { Stop-Work "결과를 받지 못했어요 ($code)" }
  $new = Join-Path $Tmp 'out'; New-Item -ItemType Directory -Force -Path $new | Out-Null
  & $Tar -xzf $res -C $new
  if ($LASTEXITCODE -ne 0) { Stop-Work '결과를 풀지 못했어요' }
  return $new
}

try {
  if ($Command -eq 'init') {
    if ((Test-Path $Dir) -and (Get-ChildItem -Force $Dir | Select-Object -First 1)) { Stop-Work "작업 폴더가 비어 있지 않아요: $Dir" }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $tgz = Join-Path $Tmp 'starter.tgz'
    $code = & $Curl -sS -o $tgz -w '%{http_code}' "$Api/starter?t=$Ticket"
    if ($LASTEXITCODE -ne 0) { Stop-Work '서버에 연결하지 못했어요. 인터넷 연결을 확인해 주세요.' }
    if ([int]$code -ne 200) { Stop-Work ('시작 파일을 받지 못했어요: ' + ([IO.File]::ReadAllText($tgz, [Text.Encoding]::UTF8) -replace '^error=', '').Trim()) }
    & $Tar -xzf $tgz -C $Dir
    if ($LASTEXITCODE -ne 0) { Stop-Work '시작 파일을 풀지 못했어요' }
    Get-ChildItem -Recurse -Force -File $Dir -Filter '.keep' | Remove-Item -Force
    Write-Output "✅ 작업 폴더를 만들었어요: $Dir"
    Get-ChildItem $Dir | ForEach-Object { Write-Output ('   ' + $_.Name) }
  }
  elseif ($Command -eq 'lint') {
    $copy = Join-Path $Dir '03_copy.md'
    if (-not (Test-Path $copy)) { Stop-Work "03_copy.md 가 없어요: $copy" }
    $r = Invoke-Api 'POST' "/lint?t=$Ticket" $copy 'text/markdown; charset=utf-8' $null
    Write-Output $r.text.TrimEnd()
  }
  elseif ($Command -eq 'merge') {
    $body = Join-Path $Tmp 'merge.txt'; [IO.File]::WriteAllText($body, 'merge')
    [void](Invoke-Api 'POST' "/jobs/start?t=$Ticket" $body 'text/plain' $null)
    Write-Output '⏳ 통이미지 만드는 중…'
    $st = Wait-Done '통이미지'
    $new = Get-Result $st.map['resultUrl']
    $dst = Join-Path $Dir 'output\merged'
    if (Test-Path $dst) { Get-ChildItem -File $dst | Remove-Item -Force } else { New-Item -ItemType Directory -Force -Path $dst | Out-Null }
    Copy-Item -Path (Join-Path $new 'merged\*') -Destination $dst -Force
    $list = @(Get-ChildItem -File $dst | Sort-Object Name)
    Write-Output ('✅ 통이미지 ' + $list.Count + '장 — output\merged')
    $list | ForEach-Object { Write-Output ('   ' + $_.Name + ' (' + [Math]::Round($_.Length / 1MB, 1) + 'MB)') }
  }
  elseif ($Command -eq 'catalog') {
    $r = Invoke-Api 'GET' "/catalog?t=$Ticket" $null $null $null
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $pack = Join-Path $Tmp 'catalog.tgz'
    $code = & $Curl -sS -o $pack -w '%{http_code}' $r.map['url']
    if ($LASTEXITCODE -ne 0 -or [int]$code -ne 200) { Stop-Work "견본을 받지 못했어요 ($code)" }
    & $Tar -xzf $pack -C $Dir
    if ($LASTEXITCODE -ne 0) { Stop-Work '견본을 풀지 못했어요' }
    Write-Output "✅ 견본을 받았어요: $Dir"
    Get-ChildItem $Dir | ForEach-Object { Write-Output ('   ' + $_.Name) }
  }
  else {
    # ---------- render ----------
    if (-not (Test-Path (Join-Path $Dir 'page.html'))) { Stop-Work "page.html 이 없어요: $Dir" }
    $files = Get-AssetFiles
    $hash = Get-AssetsHash $files
    $hashFile = Join-Path $Tmp 'hash.txt'
    [IO.File]::WriteAllText($hashFile, $hash)
    $prep = Invoke-Api 'POST' "/jobs/prepare?t=$Ticket" $hashFile 'text/plain' $null
    if ($prep.map['needAssets'] -eq '1') {
      $listFile = Join-Path $Tmp 'assets.txt'
      [IO.File]::WriteAllText($listFile, (($files | ForEach-Object { Get-Rel $_.FullName }) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
      $assetsTgz = Join-Path $Tmp 'assets.tgz'
      & $Tar -czf $assetsTgz -C $Dir -T $listFile
      if ($LASTEXITCODE -ne 0) { Stop-Work '이미지 묶음을 만들지 못했어요' }
      $size = (Get-Item $assetsTgz).Length
      if ($size -gt $AssetsMax) { Stop-Work ('이미지 묶음이 30MB를 넘어요 (' + [Math]::Round($size / 1MB, 1) + 'MB). 큰 이미지를 줄여 주세요.') }
      $code = & $Curl -sS -X PUT -H ('x-goog-content-length-range: ' + $prep.map['range']) -H 'Content-Type: application/gzip' --upload-file $assetsTgz -o (Join-Path $Tmp 'put.txt') -w '%{http_code}' $prep.map['putUrl']
      if ($LASTEXITCODE -ne 0 -or [int]$code -ge 300) { Stop-Work "이미지를 올리지 못했어요 ($code)" }
      Write-Output ('📤 이미지 ' + $files.Count + '개 올림 (' + [Math]::Round($size / 1MB, 1) + 'MB)')
    }
    $textTgz = Join-Path $Tmp 'text.tgz'
    $textFiles = @('page.html'); if (Test-Path (Join-Path $Dir 'theme.css')) { $textFiles += 'theme.css' }
    & $Tar -czf $textTgz -C $Dir @textFiles
    if ($LASTEXITCODE -ne 0) { Stop-Work 'page.html 묶음을 만들지 못했어요' }
    [void](Invoke-Api 'POST' "/jobs/start?t=$Ticket" $textTgz 'application/gzip' @{ 'X-Assets-Hash' = $hash })
    Write-Output '⏳ 렌더 중… (보통 10~60초)'
    $st = Wait-Done '렌더'
    $new = Get-Result $st.map['resultUrl']

    # output\ 에 합치기: 부분 렌더면 그 섹션 파일만 바꾸고, 전체 렌더면 해당 폴더를 새로
    $out = Join-Path $Dir 'output'; New-Item -ItemType Directory -Force -Path $out | Out-Null
    $ids = @(); if ($st.map['only']) { $ids = $st.map['only'] -split ',' | Where-Object { $_ } }
    foreach ($sub in @('1000', '2000', 'review')) {
      $src = Join-Path $new $sub
      if (-not (Test-Path $src)) { continue }
      $dst = Join-Path $out $sub; New-Item -ItemType Directory -Force -Path $dst | Out-Null
      if ($ids.Count) { foreach ($id in $ids) { Get-ChildItem -File $dst | Where-Object { $_.Name -like "${id}_*" -or $_.Name -eq "$id.png" } | Remove-Item -Force } }
      else { Get-ChildItem -File $dst -Filter '*.png' | Remove-Item -Force }
      Copy-Item -Path (Join-Path $src '*') -Destination $dst -Force
    }
    foreach ($f in @('qa-report.md', 'qa-report.json', 'page-text.md')) { $p = Join-Path $new $f; if (Test-Path $p) { Copy-Item $p $out -Force } }
    $n = Write-Preview $out

    # 자동검수 요약
    $qa = Join-Path $out 'qa-report.md'
    Write-Output ('✅ 렌더 완료 (' + $st.map['mode'] + $(if ($ids.Count) { ' · ' + ($ids -join ',') } else { ' · 전체' }) + ', 서버 ' + $st.map['seconds'] + '초) — output\1000 에 ' + $n + '장, 미리보기 output\preview.html')
    if (Test-Path $qa) {
      $head = ''; $printed = 0
      foreach ($line in (Get-Content -Encoding UTF8 $qa)) {
        if ($line -like '- 오류(error)*') { Write-Output ('   ' + $line.Substring(2)) }
        elseif ($line.StartsWith('## ')) { $head = $line.Substring(3) }
        elseif (($line.Contains('❌') -or $line.Contains('⚠️')) -and $printed -lt 40) { Write-Output ('   [' + $head + '] ' + $line.Substring(2)); $printed++ }
      }
      Write-Output '   전체 보고서: output\qa-report.md · 섹션별 확인용 조각: output\review\'
    }
  }
}
finally {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
