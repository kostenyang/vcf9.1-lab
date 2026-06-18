<#
.SYNOPSIS
    把 VCF Installer 接到 offline depot (HTTP no-auth),觸發 metadata sync。

.DESCRIPTION
    nested / air-gapped lab 用。重點眉角:
    - VCF Installer 強制走 HTTPS 連 depot;若 depot 是自簽憑證 HTTPS 會 certificate_unknown。
      → 用 HTTP no-auth depot (depot server 開一個 no-auth 埠, 例如 nginx listen 8888 無 auth_basic)。
    - depot URL **必須用 IP, 不要用 FQDN** — 9.1 installer 的 URL 驗證對 FQDN 會回
      VMWARE_DEPOT_OFFLINE_INVALID_URL;用 IP 直接過。
    - URL 給「根」即可 (http://IP:PORT),installer 自己接 /PROD。

.EXAMPLE
    pwsh ./Connect-OfflineDepot.ps1 -InstallerIp 10.0.1.4 -DepotUrl http://10.0.0.61:8888
#>
[CmdletBinding()]
param(
    [string] $InstallerIp       = '10.0.1.4',
    [string] $InstallerUser     = 'admin@local',
    [string] $InstallerPassword = 'VMware1!VMware1!',
    [string] $DepotUrl          = 'http://10.0.0.61:8888',   # 用 IP! 不要 FQDN
    [switch] $SkipSync
)
$ErrorActionPreference = 'Stop'
$base = "https://$InstallerIp"
function Get-Tok { (Invoke-RestMethod -Method Post -Uri "$base/v1/tokens" -SkipCertificateCheck -TimeoutSec 20 -ContentType 'application/json' -Body (@{username=$InstallerUser;password=$InstallerPassword}|ConvertTo-Json)).accessToken }
$h = @{ Authorization = "Bearer $(Get-Tok)"; 'Content-Type'='application/json' }

Write-Host "PUT offline depot: $DepotUrl"
$body = @{ depotConfiguration = @{ isOfflineDepot=$true; url=$DepotUrl } } | ConvertTo-Json -Depth 5
$r = Invoke-RestMethod -Method Put -Uri "$base/v1/system/settings/depot" -Headers $h -Body $body -SkipCertificateCheck -TimeoutSec 90
$st = ($r.offlineAccount.status ?? $r.vmwareAccount.status)
Write-Host ("  -> status: {0}" -f $st) -ForegroundColor $(if($st -match 'SUCCESS'){'Green'}else{'Yellow'})
if ($st -notmatch 'SUCCESS') { throw "depot 接上失敗: $($r | ConvertTo-Json -Compress)" }

if (-not $SkipSync) {
    Write-Host "觸發 metadata sync..."
    try { Invoke-RestMethod -Method Patch -Uri "$base/v1/system/settings/depot/depot-sync-info" -Headers $h -SkipCertificateCheck -TimeoutSec 60 | Out-Null } catch {}
    for ($i=0; $i -lt 20; $i++) {
        Start-Sleep 15
        $h = @{ Authorization = "Bearer $(Get-Tok)" }
        $si = Invoke-RestMethod -Uri "$base/v1/system/settings/depot/depot-sync-info" -Headers $h -SkipCertificateCheck -TimeoutSec 30
        $ss = ($si.status ?? $si.syncStatus)
        Write-Host ("  sync: {0}" -f $ss)
        if ($ss -match 'SYNC|SUCCESS|COMPLETED') { break }
    }
    $b = (Invoke-RestMethod -Uri "$base/v1/bundles" -Headers $h -SkipCertificateCheck -TimeoutSec 60).elements
    Write-Host ("bundles: {0} 總, {1} SUCCESSFUL" -f $b.Count, @($b|?{$_.downloadStatus -eq 'SUCCESSFUL'}).Count) -ForegroundColor Cyan
}
Write-Host "完成。" -ForegroundColor Green
