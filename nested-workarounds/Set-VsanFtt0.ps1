<#
.SYNOPSIS
    把 inner vCenter 的 vSAN Default Storage Policy 設成 FTT=0 + forceProvisioning,
    並可選擇 reapply 到所有現有 VM。

.DESCRIPTION
    nested vSAN lab 用。眉角:FTT=1 每次寫入要做兩份 (RAID1) = 雙倍寫延遲,
    VSP/Supervisor 的 etcd 對 fsync 延遲極敏感,nested vSAN 上 FTT=1 會把 etcd 拖到
    每操作數秒 → Supervisor 無法穩定。FTT=0 單份 → 寫延遲減半。forceProvisioning 讓物件
    即使 policy 無法完全滿足也能部署 (nested 空間/容錯有限時必要)。
    FTT 1->0 是「移除鏡像副本」,resync 輕量。

.PARAMETER ReapplyExisting
    除了改預設 policy,也把 policy reapply 到所有現有 VM + 磁碟 (含已部好的 etcd VM)。

.EXAMPLE
    pwsh ./Set-VsanFtt0.ps1 -Vc 10.0.1.19 -ReapplyExisting
#>
[CmdletBinding()]
param(
    [string] $Vc       = '10.0.1.19',
    [string] $User     = 'administrator@vsphere.local',
    [string] $Password = 'VMware1!VMware1!',
    [string] $PolicyName = 'vSAN Default Storage Policy',
    [switch] $ReapplyExisting
)
$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core
Import-Module VMware.VimAutomation.Storage -ErrorAction SilentlyContinue
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$c = Connect-VIServer -Server $Vc -User $User -Password $Password -ErrorAction Stop
try {
    $pol = Get-SpbmStoragePolicy -Server $c -Name $PolicyName
    $ftt = New-SpbmRule -Capability (Get-SpbmCapability -Server $c -Name 'VSAN.hostFailuresToTolerate') -Value 0
    $fp  = New-SpbmRule -Capability (Get-SpbmCapability -Server $c -Name 'VSAN.forceProvisioning') -Value $true
    $sw  = New-SpbmRule -Capability (Get-SpbmCapability -Server $c -Name 'VSAN.stripeWidth') -Value 1
    Set-SpbmStoragePolicy -StoragePolicy $pol -RuleSet (New-SpbmRuleSet -AllOfRules @($ftt,$fp,$sw)) -Confirm:$false | Out-Null
    Write-Host "預設 policy 已設 FTT=0 + forceProvisioning。" -ForegroundColor Green

    if ($ReapplyExisting) {
        Write-Host "Reapply 到所有現有 VM + 磁碟..."
        foreach ($vm in (Get-VM -Server $c)) {
            try {
                $cfgs = @($vm | Get-SpbmEntityConfiguration) + @(Get-HardDisk -VM $vm | Get-SpbmEntityConfiguration)
                $cfgs | Where-Object {$_} | Set-SpbmEntityConfiguration -StoragePolicy $pol -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Host ("  ✓ {0}" -f $vm.Name) -ForegroundColor Green
            } catch { Write-Host ("  ! {0}: {1}" -f $vm.Name, $_.Exception.Message.Split([Environment]::NewLine)[0]) -ForegroundColor Yellow }
        }
    }
} finally { Disconnect-VIServer -Server $c -Confirm:$false }
