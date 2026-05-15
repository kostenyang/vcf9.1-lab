<#
.SYNOPSIS
    一鍵 VCF 9.1 lab bring-up — 從 inventory + secrets 一路打到 SDDC 起來.

.DESCRIPTION
    串起 layer2 的三步:
        1. Generate-BringupSpec.ps1     讀 inventory + secrets -> generated-bringup.json
        2. Submit-Bringup.ps1 -ValidateOnly   先 validation
        3. (人類確認) -> Submit-Bringup.ps1   真的 bring-up + poll

    預設啟用 -LabMode (跳過 nested CPU / vSAN ESA HCL / NIC count 等檢查).

.PARAMETER VcfInstaller
    VCF Installer URL, 例如 https://10.0.1.5

.PARAMETER NonInteractive
    跳過 validation 後的人類確認, 直接 bring-up. CI/CD 用.

.PARAMETER SkipLabMode
    不套用 lab workaround (正式環境用).

.EXAMPLE
    # 在 automation host (10.0.0.65) 上:
    source ../scripts/load-secrets.sh
    pwsh ./New-VcfLab.ps1 -VcfInstaller https://10.0.1.5
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $VcfInstaller,
    [switch] $NonInteractive,
    [switch] $SkipLabMode
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== Step 1/3: 產生 bring-up spec ==="
# 預設讓 Generate-BringupSpec 自己用 sops 解密 inventory/secrets/lab.yaml
# 如果你想改成從 env vars 讀, 加 -SecretsAlreadyLoaded 並先 set env
$genArgs = @{
    OutputFile = (Join-Path $here 'generated-bringup.json')
}
if (-not $SkipLabMode) { $genArgs.LabMode = $true }
& (Join-Path $here 'Generate-BringupSpec.ps1') @genArgs

Write-Host ""
Write-Host "=== Step 2/3: Validation only ==="
& (Join-Path $here 'Submit-Bringup.ps1') `
    -VcfInstaller $VcfInstaller `
    -SpecFile (Join-Path $here 'generated-bringup.json') `
    -ValidateOnly

if (-not $NonInteractive) {
    Write-Host ""
    Write-Host "Validation 過了. 真的要送 bring-up 嗎? (約 1-2 小時)" -ForegroundColor Yellow
    $ans = Read-Host "輸入 'YES' 繼續, 其他結束"
    if ($ans -ne 'YES') {
        Write-Host "取消."
        return
    }
}

Write-Host ""
Write-Host "=== Step 3/3: Bring-up ==="
& (Join-Path $here 'Submit-Bringup.ps1') `
    -VcfInstaller $VcfInstaller `
    -SpecFile (Join-Path $here 'generated-bringup.json')

Write-Host ""
Write-Host "完成. 接下來建議跑 layer3-postbringup/ 的 commission / domain 腳本."
