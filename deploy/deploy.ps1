<#
.SYNOPSIS
  Deploy FeeCalc lên một "máy chủ" (ở bản demo là một thư mục), healthcheck, lỗi thì tự rollback.

.DESCRIPTION
  Cấu trúc trên máy chủ:
    <ServerRoot>\releases\<Version>\   mỗi lần deploy là một thư mục riêng, không ghi đè bản cũ
    <ServerRoot>\current.txt          phiên bản đang chạy
    <ServerRoot>\history.txt          lịch sử các bản deploy thành công (rollback.ps1 đọc file này)
    <ServerRoot>\app.pid              PID của tiến trình đang chạy
    <ServerRoot>\logs\                log stdout/stderr của app

  Máy chủ thật (VM trong VMware) dùng đúng logic này, chỉ khác phần start/stop:
  Windows Service (sc.exe / nssm) hoặc IIS app pool, Linux thì systemd.

.EXAMPLE
  ./deploy/deploy.ps1 -PackageDir ./out -ServerRoot F:\GITHUB\cicd\servers\uat -Port 5081 -Version 1.0.7 -EnvName UAT
#>
param(
    [Parameter(Mandatory)] [string] $PackageDir,
    [Parameter(Mandatory)] [string] $ServerRoot,
    [Parameter(Mandatory)] [int]    $Port,
    [Parameter(Mandatory)] [string] $Version,
    [string] $EnvName = 'Production',
    [int]    $KeepReleases = 5
)

$ErrorActionPreference = 'Stop'

$releasesDir = Join-Path $ServerRoot 'releases'
$logsDir     = Join-Path $ServerRoot 'logs'
$currentFile = Join-Path $ServerRoot 'current.txt'
$historyFile = Join-Path $ServerRoot 'history.txt'
$pidFile     = Join-Path $ServerRoot 'app.pid'
# 127.0.0.1 + -NoProxy: tránh request localhost bị đẩy qua proxy công ty
$healthUrl   = "http://127.0.0.1:$Port/health"

New-Item -ItemType Directory -Force $releasesDir, $logsDir | Out-Null
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not $dotnet) { $dotnet = 'C:\Program Files\dotnet\dotnet.exe' }

function Stop-App {
    if (Test-Path $pidFile) {
        $appPid = [int](Get-Content $pidFile)
        if (Get-Process -Id $appPid -ErrorAction SilentlyContinue) {
            Write-Host "  Dừng tiến trình cũ PID=$appPid"
            taskkill /PID $appPid /T /F | Out-Null   # /T: kill cả cây (cmd.exe + dotnet.exe)
            Start-Sleep -Seconds 1
        }
        Remove-Item $pidFile -Force
    }
}

function Start-App([string] $ver) {
    $dir = Join-Path $releasesDir $ver
    Write-Host "  Khởi động $ver tại http://localhost:$Port"
    $env:ASPNETCORE_ENVIRONMENT = $EnvName
    # GitHub runner tự kill mọi tiến trình mà job tạo ra khi job kết thúc.
    # Xoá biến này để app tiếp tục chạy sau khi pipeline xong (máy chủ thật dùng Windows Service thì không cần).
    $env:RUNNER_TRACKING_ID = ''
    # Chạy qua cmd.exe và để cmd tự ghi log, KHÔNG dùng -RedirectStandardOutput của Start-Process:
    # cách đó làm app kế thừa pipe stdout của runner -> bước deploy treo đến khi app tắt.
    $out = Join-Path $logsDir "$ver.out.log"
    $err = Join-Path $logsDir "$ver.err.log"
    $cmd = "`"`"$dotnet`" `"$dir\FeeCalc.Api.dll`" --urls http://localhost:$Port > `"$out`" 2> `"$err`"`""
    $proc = Start-Process cmd.exe -ArgumentList '/c', $cmd -WorkingDirectory $dir -WindowStyle Hidden -PassThru
    Set-Content $pidFile $proc.Id
}

function Test-Health([string] $ver) {
    $appPid = [int](Get-Content $pidFile)
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) {
            Write-Host "  Tiến trình PID=$appPid đã thoát (app crash khi khởi động)"
            return $false
        }
        try {
            $r = Invoke-RestMethod $healthUrl -TimeoutSec 3 -NoProxy
            if ($r.status -eq 'ok' -and ($r.version -eq $ver -or $r.version -like "$ver+*")) {
                Write-Host "  Healthcheck OK (lần $i): $($r | ConvertTo-Json -Compress)"
                return $true
            }
            Write-Host "  Lần $i`: app trả về phiên bản '$($r.version)', chờ '$ver'"
        } catch {
            Write-Host "  Lần $i`: chưa sẵn sàng ($($_.Exception.Message))"
        }
    }
    return $false
}

$previous = if (Test-Path $currentFile) { (Get-Content $currentFile).Trim() } else { $null }
Write-Host "== Deploy $Version lên $EnvName ($ServerRoot). Bản đang chạy: $(if ($previous) { $previous } else { '(chưa có)' })"

# 1. Chép gói mới vào thư mục release riêng
$target = Join-Path $releasesDir $Version
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
Copy-Item $PackageDir $target -Recurse
Write-Host "1. Đã chép gói vào $target"

# 2. Thay tiến trình
Write-Host '2. Chuyển sang bản mới'
Stop-App
Start-App $Version

# 3. Healthcheck, lỗi thì rollback
Write-Host '3. Healthcheck'
if (Test-Health $Version) {
    Set-Content $currentFile $Version
    Add-Content $historyFile "$Version`t$(Get-Date -Format s)"
    # Dọn release cũ, giữ lại $KeepReleases bản gần nhất để còn rollback
    Get-ChildItem $releasesDir -Directory | Sort-Object CreationTime -Descending |
        Select-Object -Skip $KeepReleases | Remove-Item -Recurse -Force
    Write-Host "== THÀNH CÔNG: $EnvName đang chạy $Version"
    exit 0
}

Write-Host "!! Healthcheck THẤT BẠI. Log: $logsDir\$Version.err.log"
Stop-App
Remove-Item $target -Recurse -Force   # không giữ bản lỗi, để rollback không bao giờ chọn nhầm nó
if ($previous) {
    Write-Host "!! ROLLBACK về $previous"
    Start-App $previous
    if (Test-Health $previous) { Write-Host "== Đã rollback, $EnvName chạy lại $previous" }
    else { Write-Host '!! Rollback cũng lỗi, cần xử lý tay ngay' }
}
exit 1
