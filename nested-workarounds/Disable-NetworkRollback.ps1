<#
.SYNOPSIS
    在 inner (mgmt) vCenter 設 config.vpxd.network.rollback = false。

.DESCRIPTION
    nested lab 用。眉角:vmk0 從 standard switch 遷到 vDS 時,nested 環境 L2 收斂慢,
    vCenter 偵測到 host 短暫失聯會在幾秒內自動 rollback → 任務失敗。關掉 network rollback
    讓 vmk 遷移撐過收斂窗口。
    時機:inner vCenter 部好、SSO 起來後,host vmk 遷 vDS 之前。每次 vCenter 重部會重置回 true。

.EXAMPLE
    pwsh ./Disable-NetworkRollback.ps1 -Vc 10.0.1.19
#>
[CmdletBinding()]
param(
    [string] $Vc       = '10.0.1.19',
    [string] $User     = 'administrator@vsphere.local',
    [string] $Password = 'VMware1!VMware1!',
    [int]    $RetryMinutes = 8
)
$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$deadline = (Get-Date).AddMinutes($RetryMinutes)
do {
    try {
        $c = Connect-VIServer -Server $Vc -User $User -Password $Password -ErrorAction Stop
        $si = Get-View ServiceInstance -Server $c
        $sm = Get-View $si.Content.Setting -Server $c
        $opt = New-Object VMware.Vim.OptionValue; $opt.Key='config.vpxd.network.rollback'; $opt.Value='false'
        $sm.UpdateOptions(@($opt))
        $cur = ($sm.QueryOptions('config.vpxd.network.rollback'))[0].Value
        Write-Host "config.vpxd.network.rollback = $cur" -ForegroundColor Green
        Disconnect-VIServer -Server $c -Confirm:$false
        return
    } catch {
        Write-Host ("  SSO 未就緒, 重試: {0}" -f $_.Exception.Message.Split([Environment]::NewLine)[0]) -ForegroundColor DarkGray
        Start-Sleep 30
    }
} while ((Get-Date) -lt $deadline)
throw "$RetryMinutes 分鐘內無法設定 (vCenter 沒就緒?)"
