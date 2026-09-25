<#
.SYNOPSIS
  Rollback thủ công: chạy lại một release cũ đã có sẵn trên máy chủ (không cần build lại).

.EXAMPLE
  ./deploy/rollback.ps1 -ServerRoot F:\GITHUB\cicd\servers\prod -Port 5082 -EnvName Production
  ./deploy/rollback.ps1 -ServerRoot F:\GITHUB\cicd\servers\prod -Port 5082 -EnvName Production -Version 1.0.3
#>
param(
    [Parameter(Mandatory)] [string] $ServerRoot,
    [Parameter(Mandatory)] [int]    $Port,
    [string] $Version,                  # bỏ trống = bản deploy thành công gần nhất trước bản đang chạy
    [string] $EnvName = 'Production'
)

$ErrorActionPreference = 'Stop'
$releasesDir = Join-Path $ServerRoot 'releases'
$current = (Get-Content (Join-Path $ServerRoot 'current.txt')).Trim()

if (-not $Version) {
    $history = @(Get-Content (Join-Path $ServerRoot 'history.txt') | ForEach-Object { ($_ -split "`t")[0] })
    [array]::Reverse($history)
    $Version = $history | Where-Object { $_ -ne $current -and (Test-Path (Join-Path $releasesDir $_)) } |
        Select-Object -First 1
    if (-not $Version) { throw 'Không còn release cũ nào để rollback' }
}

Write-Host "Rollback $EnvName`: $current -> $Version"
# Tái dùng deploy.ps1: "gói" chính là thư mục release cũ, được chép sang một bản tạm rồi deploy lại
$tmp = Join-Path ([IO.Path]::GetTempPath()) "feecalc-rollback-$Version"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Copy-Item (Join-Path $releasesDir $Version) $tmp -Recurse
& (Join-Path $PSScriptRoot 'deploy.ps1') -PackageDir $tmp -ServerRoot $ServerRoot -Port $Port -Version $Version -EnvName $EnvName
$code = $LASTEXITCODE
Remove-Item $tmp -Recurse -Force
exit $code
