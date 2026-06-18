<#
.SYNOPSIS
    Toggle 外層 trunk portgroup 的 AllowPromiscuous (False->True),強制重推 swsec policy。

.DESCRIPTION
    nested ESXi lab 用。眉角:外層 ESXi 7.x 的 dvSwitch swsec runtime 狀態會 stale —
    portgroup 設定顯示 Promiscuous/MacLearning=True,但實際 port 沒套用、丟封包,
    導致 nested ESXi 部署後 vmk0 ping 不到(連 vCenter 也加不進來)。
    Toggle promiscuous False->True 會把 policy 重新推到所有 port,nested ESXi 立刻通。
    每次重部 nested ESXi 後若連不到,跑這支。

.EXAMPLE
    pwsh ./Reset-TrunkPromiscuous.ps1 -OuterVc 10.0.0.101 -Portgroup Trunk-Nobinding
#>
[CmdletBinding()]
param(
    [string] $OuterVc       = '10.0.0.101',
    [string] $OuterUser     = 'administrator@vsphere.local',
    [string] $OuterPassword = 'VMware1!',
    [string] $Portgroup     = 'Trunk-Nobinding'
)
$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$vc = Connect-VIServer -Server $OuterVc -User $OuterUser -Password $OuterPassword -ErrorAction Stop
try {
    $pg = Get-VDPortgroup -Server $vc -Name $Portgroup
    $before = ($pg | Get-VDSecurityPolicy).AllowPromiscuous
    Write-Host "Before AllowPromiscuous = $before"
    $pg | Get-VDSecurityPolicy | Set-VDSecurityPolicy -AllowPromiscuous $false -Confirm:$false | Out-Null
    Start-Sleep 4
    $pg | Get-VDSecurityPolicy | Set-VDSecurityPolicy -AllowPromiscuous $true -Confirm:$false | Out-Null
    Write-Host "Toggle 完成 (False->True 重推 swsec policy)。" -ForegroundColor Green
    Write-Host "nested ESXi 幾秒內應可 ping。"
} finally { Disconnect-VIServer -Server $vc -Confirm:$false }
