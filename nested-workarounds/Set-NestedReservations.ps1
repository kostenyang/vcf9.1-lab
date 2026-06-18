<#
.SYNOPSIS
    在外層 vCenter 給 nested ESXi VM 設 CPU / Memory reservation。

.DESCRIPTION
    nested lab 用。眉角:外層 host 常被很多 VM 超賣 (overcommit),nested ESXi 被 balloon/swap
    時,其內部 vSAN / VSP etcd 的 I/O 會經過 swap → 災難級延遲。設 reservation 保證 nested ESXi
    拿到實體 CPU/RAM,不被 swap,降低 etcd 延遲、穩定 VSP。
    Memory 用降級嘗試 (256->192->128->96->64GB):外層容量不足時自動套放得下的最大值。

.EXAMPLE
    pwsh ./Set-NestedReservations.ps1 -OuterVc 10.0.0.101 -VmPattern 'vcf-m02-esx0*-91' -CpuMhz 16000 -MemGB 256
#>
[CmdletBinding()]
param(
    [string] $OuterVc       = '10.0.0.101',
    [string] $OuterUser     = 'administrator@vsphere.local',
    [string] $OuterPassword = 'VMware1!',
    [string] $VmPattern     = 'vcf-m02-esx0*-91',
    [int]    $CpuMhz        = 16000,
    [int]    $MemGB         = 256
)
$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$c = Connect-VIServer -Server $OuterVc -User $OuterUser -Password $OuterPassword -ErrorAction Stop
try {
    $vms = Get-VM -Server $c -Name $VmPattern | Sort-Object Name
    Write-Host ("符合 '{0}' 的 VM: {1} 台" -f $VmPattern, $vms.Count)
    foreach ($vm in $vms) {
        try { $vm | Get-VMResourceConfiguration | Set-VMResourceConfiguration -CpuReservationMhz $CpuMhz -Confirm:$false | Out-Null
              Write-Host ("  {0}: CPU rsv {1} MHz" -f $vm.Name,$CpuMhz) -ForegroundColor Green } catch { Write-Host ("  {0}: CPU rsv fail" -f $vm.Name) -ForegroundColor Yellow }
        $set = $false
        foreach ($g in @($MemGB,192,128,96,64) | Sort-Object -Descending -Unique | Where-Object {$_ -le $MemGB}) {
            try { $vm | Get-VMResourceConfiguration | Set-VMResourceConfiguration -MemReservationGB $g -Confirm:$false -ErrorAction Stop | Out-Null
                  Write-Host ("  {0}: Mem rsv {1} GB" -f $vm.Name,$g) -ForegroundColor Green; $set=$true; break } catch {}
        }
        if (-not $set) { Write-Host ("  {0}: Mem rsv 連最低都設不了 (外層容量不足)" -f $vm.Name) -ForegroundColor Yellow }
    }
} finally { Disconnect-VIServer -Server $c -Confirm:$false }
