<#
.SYNOPSIS
    關掉 inner (mgmt) cluster 的 HA Admission Control。

.DESCRIPTION
    nested / 小容量 lab 用。眉角:VSP (VCF Management Services Platform / Supervisor) 部署時,
    HA Admission Control 開著會保留容量,擋住 VSP appliance 放置 →
    "Monitor VCF Management Services Deployment Task" 卡住、VSP VM 一直起不來。
    關掉 admission control 後 VSP appliance 立刻能部署。
    時機:cluster 形成後、VSP 階段(若卡在 VSP 且 inner vCenter 看不到 VSP VM)。

.EXAMPLE
    pwsh ./Disable-HaAdmissionControl.ps1 -Vc 10.0.1.19
#>
[CmdletBinding()]
param(
    [string] $Vc       = '10.0.1.19',
    [string] $User     = 'administrator@vsphere.local',
    [string] $Password = 'VMware1!VMware1!'
)
$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$c = Connect-VIServer -Server $Vc -User $User -Password $Password -ErrorAction Stop
try {
    Get-Cluster -Server $c | ForEach-Object {
        Write-Host ("{0}: AdmissionControl {1} -> 關閉中" -f $_.Name, $_.HAAdmissionControlEnabled)
        Set-Cluster -Cluster $_ -HAAdmissionControlEnabled $false -Confirm:$false | Out-Null
        $a = (Get-Cluster -Server $c -Name $_.Name).HAAdmissionControlEnabled
        Write-Host ("  -> AdmissionControl = {0}" -f $a) -ForegroundColor Green
    }
} finally { Disconnect-VIServer -Server $c -Confirm:$false }
