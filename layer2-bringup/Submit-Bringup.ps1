<#
.SYNOPSIS
    把產好的 bring-up JSON 推到 VCF Installer API, 並 poll 狀態到完成 / 失敗.

.PARAMETER VcfInstaller
    VCF Installer URL, 例如 https://10.0.1.5 或 https://vcf-installer.lab.com
    (不需要結尾斜線)

.PARAMETER SpecFile
    Generate-BringupSpec.ps1 產出的 JSON 檔.

.PARAMETER User
    VCF Installer admin 帳號. 預設 'admin@local'.

.PARAMETER ValidateOnly
    只送 validation, 不真的 bring-up.

.PARAMETER PollInterval
    Poll 間隔秒數, 預設 60.

.PARAMETER Token
    可選: 已經拿到 token (JWT) 的話直接傳, 跳過登入.

.EXAMPLE
    # 從 generated-bringup.json 推到 VCF Installer
    pwsh ./Submit-Bringup.ps1 -VcfInstaller https://10.0.1.5 -SpecFile ./generated-bringup.json

.NOTES
    端點以 VCF 9 公開 API 為主: /v1/sddcs/validations (POST), /v1/sddcs (POST),
    /v1/sddcs/{id} (GET). 9.1 路徑若有變動以官方 Swagger 為準.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $VcfInstaller,
    [Parameter(Mandatory=$true)] [string] $SpecFile,
    [string] $User = 'admin@local',
    [switch] $ValidateOnly,
    [int]    $PollInterval = 60,
    [string] $Token
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SpecFile)) { throw "Spec 檔不存在: $SpecFile" }
$specJson = Get-Content -Raw $SpecFile

# Self-signed cert
if (-not ('TrustAllCertsPolicy' -as [type])) {
    Add-Type -TypeDefinition @'
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
    }
'@
}
[System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCertsPolicy]::new()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = $VcfInstaller.TrimEnd('/')

#---------- 1. Auth -------------------------------------------------------
if (-not $Token) {
    Write-Host "登入 $base..."
    $pw = if ($env:VCF_INSTALLER_PW) { $env:VCF_INSTALLER_PW } else {
        Read-Host -AsSecureString "Password for $User" |
            ConvertFrom-SecureString -AsPlainText
    }
    $authBody = @{ username = $User; password = $pw } | ConvertTo-Json
    $authResp = Invoke-RestMethod -Uri "$base/v1/tokens" -Method Post -Body $authBody `
                  -ContentType 'application/json' -SkipCertificateCheck
    $Token = $authResp.accessToken
    if (-not $Token) { throw "登入失敗, 回應沒有 accessToken: $($authResp | ConvertTo-Json -Compress)" }
    Write-Host "  -> Token 取到"
}
$headers = @{
    'Authorization' = "Bearer $Token"
    'Content-Type'  = 'application/json'
}

#---------- 2. Validation -------------------------------------------------
Write-Host ""
Write-Host "送 validation..." -ForegroundColor Cyan
$valResp = Invoke-RestMethod -Uri "$base/v1/sddcs/validations" -Method Post `
              -Headers $headers -Body $specJson -SkipCertificateCheck
$valId = $valResp.id
Write-Host "  validationId: $valId"

# Poll validation
do {
    Start-Sleep 10
    $v = Invoke-RestMethod -Uri "$base/v1/sddcs/validations/$valId" -Headers $headers -SkipCertificateCheck
    Write-Host ("  status: {0}" -f $v.executionStatus)
} while ($v.executionStatus -in @('IN_PROGRESS','PENDING'))

if ($v.executionStatus -ne 'COMPLETED' -or $v.resultStatus -ne 'SUCCEEDED') {
    Write-Host ""
    Write-Host "Validation FAILED. 詳細:" -ForegroundColor Red
    $v.validationChecks | Where-Object { $_.resultStatus -ne 'SUCCEEDED' } |
        Select-Object description, resultStatus, errorResponse |
        Format-List
    throw "Validation 沒過. 修 spec 或加 -LabMode 重產."
}
Write-Host "Validation OK ✓" -ForegroundColor Green

if ($ValidateOnly) {
    Write-Host "ValidateOnly 模式, 不送 bring-up. 結束."
    return
}

#---------- 3. Submit bring-up --------------------------------------------
Write-Host ""
Write-Host "送 bring-up..." -ForegroundColor Cyan
$bringupResp = Invoke-RestMethod -Uri "$base/v1/sddcs" -Method Post `
                  -Headers $headers -Body $specJson -SkipCertificateCheck
$sddcId = $bringupResp.id
Write-Host "  sddcId: $sddcId"
Write-Host "  task 已啟動, 開始 poll (每 $PollInterval 秒)..."

#---------- 4. Poll -------------------------------------------------------
$lastPct = -1
do {
    Start-Sleep $PollInterval
    $s = Invoke-RestMethod -Uri "$base/v1/sddcs/$sddcId" -Headers $headers -SkipCertificateCheck
    $pct = $s.completionPercent
    $st  = $s.status

    if ($pct -ne $lastPct -or $st -ne $lastSt) {
        $stage = if ($s.currentStage) { $s.currentStage.name } else { '' }
        Write-Host ("  [{0,3}%] {1,-12} {2}" -f $pct, $st, $stage)
        $lastPct = $pct
        $lastSt  = $st
    }
} while ($st -in @('IN_PROGRESS','PENDING','RUNNING'))

#---------- 5. Result -----------------------------------------------------
Write-Host ""
if ($st -eq 'COMPLETED' -or $s.resultStatus -eq 'SUCCESS') {
    Write-Host "🎉  Bring-up SUCCESS" -ForegroundColor Green
    Write-Host "  SDDC Manager : $($s.sddcManagerSpec.hostname).$($s.dnsSpec.subdomain)"
    Write-Host "  vCenter      : $($s.vcenterSpec.vcenterHostname).$($s.dnsSpec.subdomain)"
    Write-Host "  NSX VIP      : $($s.nsxtSpec.vip)"
} else {
    Write-Host "Bring-up FAILED. Status = $st" -ForegroundColor Red
    Write-Host "  到 VCF Installer UI 看詳細 log, 或:"
    Write-Host "  Invoke-RestMethod -Uri '$base/v1/sddcs/$sddcId/logs' -Headers `$headers"
    exit 1
}
