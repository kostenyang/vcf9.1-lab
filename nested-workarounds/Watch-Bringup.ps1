<#
.SYNOPSIS
    監控 VCF Installer bring-up 進度 (里程碑 / 完成數 / 終態)。

.DESCRIPTION
    poll /v1/sddcs/{id},印里程碑轉換與 done 計數,到完成/失敗就停。
    沒給 -SddcId 會自動抓 installer 上目前 IN_PROGRESS 的那個。

.EXAMPLE
    pwsh ./Watch-Bringup.ps1 -InstallerIp 10.0.1.4
    pwsh ./Watch-Bringup.ps1 -InstallerIp 10.0.1.4 -SddcId 543c864c-... -IntervalSec 120
#>
[CmdletBinding()]
param(
    [string] $InstallerIp       = '10.0.1.4',
    [string] $InstallerUser     = 'admin@local',
    [string] $InstallerPassword = 'VMware1!VMware1!',
    [string] $SddcId,
    [int]    $IntervalSec       = 120,
    [int]    $MaxHours          = 6
)
$ErrorActionPreference = 'Stop'
$base = "https://$InstallerIp"
function Get-Tok { (Invoke-RestMethod -Method Post -Uri "$base/v1/tokens" -SkipCertificateCheck -TimeoutSec 20 -ContentType 'application/json' -Body (@{username=$InstallerUser;password=$InstallerPassword}|ConvertTo-Json)).accessToken }
if (-not $SddcId) {
    $all = Invoke-RestMethod -Uri "$base/v1/sddcs" -Headers @{Authorization="Bearer $(Get-Tok)"} -SkipCertificateCheck -TimeoutSec 30
    $SddcId = ($all.elements ?? $all | Where-Object { $_.status -match 'IN_PROGRESS|RUNNING' } | Select-Object -First 1).id
    if (-not $SddcId) { throw "找不到進行中的 bring-up,請給 -SddcId" }
    Write-Host "自動偵測 sddcId: $SddcId"
}
$lastMile=''; $iters = [int](($MaxHours*3600)/$IntervalSec)
for ($i=0; $i -lt $iters; $i++) {
    try {
        $h = @{ Authorization = "Bearer $(Get-Tok)" }
        $s = Invoke-RestMethod -Uri "$base/v1/sddcs/$SddcId" -Headers $h -SkipCertificateCheck -TimeoutSec 30
        $done = @($s.sddcSubTasks | Where-Object { $_.status -match 'COMPLETED_WITH_SUCCESS|SUCCESSFUL' }).Count
        $tot  = $s.sddcSubTasks.Count
        $t    = $s.sddcSubTasks | Where-Object { $_.status -in 'IN_PROGRESS','RUNNING' } | Select-Object -First 1
        $mile = $t.milestoneTask
        if ($mile -ne $lastMile) { Write-Host ("[{0}] done={1}/{2} {3} / {4}" -f (Get-Date -Format 'HH:mm'),$done,$tot,$mile,$t.name); $lastMile=$mile }
        if ($s.status -match 'COMPLETED_WITH_SUCCESS|^SUCCESS|^COMPLETED$|^Active$') { Write-Host "=== SUCCESS: $($s.status) ===" -ForegroundColor Green; return }
        if ($s.status -match 'FAIL|ERROR') { Write-Host "=== FAILED: $($s.status) @ $mile/$($t.name) ===" -ForegroundColor Red; return }
    } catch {}
    Start-Sleep $IntervalSec
}
Write-Host "=== 監控逾時 ($MaxHours h),bring-up 仍在跑 ==="
