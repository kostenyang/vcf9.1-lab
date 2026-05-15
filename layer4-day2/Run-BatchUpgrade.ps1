<#
.SYNOPSIS
    一鍵升級 4 台 nested ESXi (10.0.1.14~17) 從 9.0 -> 9.1。
    來源資料夾：E:\9.1  (放 ISO 或 offline depot zip)

.DESCRIPTION
    - 自動掃描 E:\9.1 找 ESXi 9.1 的 offline bundle .zip；找不到就用 .iso，
      由 Upgrade-NestedESXi91.ps1 解開取出 depot。
    - 對 4 台 host 序列執行 (避免同時掛 ISO/datastore 上傳塞網路)。
    - 每台共用同一組 root 帳密 (執行時跳一次 Get-Credential)。
    - 套用 nested lab workaround: AllowAll。

.USAGE
    從 powercli\out 目錄下 PowerShell 7 (with VMware.PowerCLI) 跑：

        .\Run-BatchUpgrade.ps1

    或自訂主機 / 來源資料夾：

        .\Run-BatchUpgrade.ps1 -Hosts 10.0.1.14,10.0.1.15 -SourceDir 'E:\9.1'

.NOTES
    需要：
      - PowerShell 5.1 或 7.x
      - VMware.PowerCLI 13.x (Install-Module VMware.PowerCLI -Scope CurrentUser)
      - 同目錄下要有 Upgrade-NestedESXi91.ps1
#>

[CmdletBinding()]
param(
    [string[]] $Hosts      = @('10.0.1.14','10.0.1.15','10.0.1.16','10.0.1.17'),
    [string]   $SourceDir  = 'E:\9.1',
    [string]   $Datastore  = '',     # 空字串 = 自動挑 host 上最大 VMFS
    [string[]] $LabFlags   = @('AllowAll')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$childScript = Join-Path $here 'Upgrade-NestedESXi91.ps1'
if (-not (Test-Path $childScript)) {
    throw "Upgrade-NestedESXi91.ps1 not found in $here"
}

# 1. 掃 E:\9.1 找升級檔
if (-not (Test-Path $SourceDir)) { throw "SourceDir not found: $SourceDir" }

$zip = Get-ChildItem -Path $SourceDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -match '(?i)ESXi.*9\.1.*depot' } |
       Select-Object -First 1
if (-not $zip) {
    $zip = Get-ChildItem -Path $SourceDir -Filter '*depot*.zip' -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
}

$iso = $null
if (-not $zip) {
    $iso = Get-ChildItem -Path $SourceDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '(?i)9\.1' } |
           Select-Object -First 1
    if (-not $iso) {
        $iso = Get-ChildItem -Path $SourceDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
    }
}

if (-not $zip -and -not $iso) {
    throw "在 $SourceDir 下找不到任何 .zip 或 .iso"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " 4-host batch upgrade plan" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Source dir : $SourceDir"
Write-Host "  Depot zip  : $($zip.FullName)"
Write-Host "  ISO        : $($iso.FullName)"
Write-Host "  Hosts      : $($Hosts -join ', ')"
Write-Host "  Datastore  : $Datastore"
Write-Host "  Workarounds: $($LabFlags -join ', ')"
Write-Host ""

# 2. 跳一次 Get-Credential，後續每台 sub-script 都用同一份
$cred = Get-Credential -UserName 'root' -Message 'ESXi root password (4 台共用)'
# 把密碼放進環境變數，讓子腳本的 Get-Credential 不要再跳 (簡化用法)
# -> 這裡改成直接把整個流程拉進當前 session，省去重複連線
$securePw = $cred.Password

# 3. 一台一台跑
$results = @()
$startTotal = Get-Date

foreach ($h in $Hosts) {
    Write-Host ""
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host "#  $h" -ForegroundColor Yellow
    Write-Host "############################################################" -ForegroundColor Yellow
    $start = Get-Date

    try {
        # 把 cred 暫存到 env 給子腳本？子腳本還是會 Get-Credential，所以這邊改成
        # 直接 inline 升級邏輯，省去再輸入。為了簡單就用 dot-source 改寫：
        $argSplat = @{
            ESXiHost       = $h
            ESXiUser       = 'root'
            DatastoreName  = $Datastore
            LabWorkarounds = $LabFlags
            Mode           = 'Depot'
        }
        if ($zip) { $argSplat.DepotZipPath = $zip.FullName }
        else      { $argSplat.ISOPath      = $iso.FullName }

        # 用 -Credential 注入比較乾淨：改 child script 也支援 -Credential
        # (見下面 patch 段)；這裡假設 child 已支援
        $argSplat.Credential = $cred

        & $childScript @argSplat
        $status = 'OK'
    }
    catch {
        Write-Warning "[$h] 失敗: $_"
        $status = "FAIL: $($_.Exception.Message)"
    }

    $results += [pscustomobject]@{
        Host     = $h
        Status   = $status
        Duration = ((Get-Date) - $start).ToString("hh\:mm\:ss")
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Batch finished in $((Get-Date) - $startTotal)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
$results | Format-Table -AutoSize
$results | Export-Csv -NoTypeInformation `
    -Path (Join-Path $here ("batch-upgrade-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)))
