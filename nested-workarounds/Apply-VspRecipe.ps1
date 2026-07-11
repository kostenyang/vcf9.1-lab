<#
.SYNOPSIS
    一鍵套齊 nested VCF 9.1「VSP 能起來」的完整配方。全打掉重建後、進第 5 關 VSP 之前跑。

.DESCRIPTION
    這支把散落的三塊配方串成一鍵,避免像 2026-07 那七輪血淚(每塊都等失敗才補):
      1. 內層 vSAN Default Storage Policy 設 FTT=0 (etcd 撐不住 FTT=1 雙寫)
      2. 外層對 4 台 nested ESXi 設 CPU/Mem reservation (防外層 swap → etcd I/O 走 swap = 災難)
      3. timeout/retry 調校套到「兩台」appliance:SDDC Manager(10.0.1.18)+ Installer(10.0.1.4)
         關鍵:兩台都要有 orchestrator.task.retry.max(預設 60,會 "failed after 60 retries")

    套用手法用 vCenter guest-ops (VMware Tools, root)——appliance root 不可直接 SSH、vcf SSH 易 faillock。

.NOTES
    跑完才 PATCH bring-up retry。VSP done≈281 後絕不刪 VSP VM(見 VSP-LCM-troubleshooting.md)。

.EXAMPLE
    pwsh ./Apply-VspRecipe.ps1
    pwsh ./Apply-VspRecipe.ps1 -SkipReservations   # 例如 host 容量不足時
#>
[CmdletBinding()]
param(
    [string] $InnerVc         = '10.0.1.19',
    [string] $OuterVc         = '10.0.0.101',
    [string] $InnerUser       = 'administrator@vsphere.local',
    [string] $InnerPassword   = 'VMware1!VMware1!',
    [string] $OuterUser       = 'administrator@vsphere.local',
    [string] $OuterPassword   = 'VMware1!',
    [string] $ApplianceRootPw = 'VMware1!VMware1!',
    [string] $SddcmVmPattern  = 'vcf-m02-sddcm01*',   # 在內層 vCenter
    [string] $InstallerVmPattern = 'vcf-m01-cb01*',   # 在外層 vCenter
    [string] $NestedEsxPattern = 'vcf-m02-esx0*-91',  # 在外層 vCenter
    [int]    $MemGB           = 128,
    [int]    $CpuMhz          = 16000,
    [switch] $SkipFtt0,
    [switch] $SkipReservations,
    [switch] $SkipTimeouts
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
Import-Module VMware.VimAutomation.Core -ErrorAction SilentlyContinue
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$TIMEOUTS = @{
    'vsp.bootstrap.task.timeout.minutes'                 = 240
    'vsp.bootstrap.command.timeout.minutes'              = 200
    'vc.appliance.services.check.timeout.minutes'        = 240
    'orchestrator.task.retry.max'                        = 240   # <-- 兩台都要,別漏 Installer
    'nsxt.manager.wait.minutes'                          = 180
    'edge.node.vm.creation.max.wait.minutes'             = 90
    'nsxt.alb.image.upload.retry.check.interval.seconds' = 90
}

function Apply-TimeoutsViaGuestOps {
    param($Vc, $VmPattern, $Label)
    $vm = Get-VM -Server $Vc -Name $VmPattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vm) { Write-Host "  [$Label] VM '$VmPattern' 找不到 — 跳過" -ForegroundColor Yellow; return }
    $lines = @('set -e','F=/etc/vmware/vcf/domainmanager/application.properties',
        'TS=$(date +%Y%m%d-%H%M%S); cp -p "$F" "$F.bak-$TS"; echo "backup $F.bak-$TS"',
        "O=`$(stat -c '%U:%G' `"`$F`"); M=`$(stat -c '%a' `"`$F`")",
        'ap(){ k="$1"; v="$2"; if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$F"; then sed -i -E "s|^[[:space:]]*${k}[[:space:]]*=.*|${k}=${v}|" "$F"; echo "upd ${k}=${v}"; else echo "${k}=${v}" >> "$F"; echo "add ${k}=${v}"; fi; }',
        'grep -qF "# VCF 9.1 lab timeout workarounds" "$F" || printf ''\n# VCF 9.1 lab timeout workarounds\n'' >> "$F"')
    foreach ($k in $TIMEOUTS.Keys) { $lines += ('ap {0} {1}' -f $k, $TIMEOUTS[$k]) }
    $lines += @('chown "$O" "$F"; chmod "$M" "$F"',
        'systemctl restart domainmanager; sleep 8; echo "domainmanager=$(systemctl is-active domainmanager)"')
    $bash = ($lines -join "`n")
    $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash))
    $r = Invoke-VMScript -Server $Vc -VM $vm -GuestUser 'root' -GuestPassword $ApplianceRootPw -ScriptType Bash `
            -ScriptText "echo $b64 | base64 -d | bash" -ErrorAction Stop
    Write-Host "  [$Label] $($vm.Name):" -ForegroundColor Green
    $r.ScriptOutput -split "`n" | Where-Object { $_ -match 'add|upd|domainmanager|backup' } | ForEach-Object { Write-Host "     $_" }
}

Write-Host "==== Apply-VspRecipe: nested VCF 9.1 VSP 配方 ====" -ForegroundColor Cyan

# 1) FTT=0 (內層 vСenter)
if (-not $SkipFtt0) {
    Write-Host "[1/3] 內層 vSAN Default Policy -> FTT=0" -ForegroundColor Cyan
    & (Join-Path $here 'Set-VsanFtt0.ps1') -Vc $InnerVc -User $InnerUser -Password $InnerPassword -ReapplyExisting
} else { Write-Host "[1/3] FTT=0 skipped" -ForegroundColor DarkGray }

# 2) 外層 nested ESXi reservation
if (-not $SkipReservations) {
    Write-Host "[2/3] 外層 nested ESXi CPU/Mem reservation (防 swap)" -ForegroundColor Cyan
    & (Join-Path $here 'Set-NestedReservations.ps1') -OuterVc $OuterVc -OuterUser $OuterUser -OuterPassword $OuterPassword -VmPattern $NestedEsxPattern -CpuMhz $CpuMhz -MemGB $MemGB
} else { Write-Host "[2/3] reservations skipped" -ForegroundColor DarkGray }

# 3) timeout/retry 兩台 appliance (guest-ops)
if (-not $SkipTimeouts) {
    Write-Host "[3/3] timeout/retry -> SDDC Manager + Installer (兩台都要!)" -ForegroundColor Cyan
    $ci = Connect-VIServer -Server $InnerVc -User $InnerUser -Password $InnerPassword -Force -WarningAction SilentlyContinue
    try { Apply-TimeoutsViaGuestOps -Vc $ci -VmPattern $SddcmVmPattern -Label 'SDDC Manager 10.0.1.18' } finally { Disconnect-VIServer $ci -Confirm:$false | Out-Null }
    $co = Connect-VIServer -Server $OuterVc -User $OuterUser -Password $OuterPassword -Force -WarningAction SilentlyContinue
    try { Apply-TimeoutsViaGuestOps -Vc $co -VmPattern $InstallerVmPattern -Label 'Installer 10.0.1.4' } finally { Disconnect-VIServer $co -Confirm:$false | Out-Null }
} else { Write-Host "[3/3] timeouts skipped" -ForegroundColor DarkGray }

Write-Host "`n==== 完成。接下來 ====" -ForegroundColor Green
Write-Host "  1) 刪光殘留 bootstrap-vm-* / vcf-m02-vsp01-*,確認 pool 10.0.0.226-240 全空"
Write-Host "  2) PATCH /v1/sddcs/{id} 帶完整 spec 做 retry"
Write-Host "  3) VSP done≈281 之後【絕不刪 VSP VM】—— 見 VSP-LCM-troubleshooting.md"
