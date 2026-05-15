<#
.SYNOPSIS
    在 VCF 部署前，對每台 nested ESXi 套用 vSAN advanced settings。

.DESCRIPTION
    套用以下 advanced settings（William Lam VCF 9.1 lab workarounds）：
        /LSOM/VSANDeviceMonitoring        = 0
        /LSOM/lsomSlowDeviceUnmount       = 0
        /VSAN/SwapThickProvisionDisabled  = 1
        /VSAN/Vsan2ZdomCompZstd           = 0
        /VSAN/FakeSCSIReservations        = 1
        /VSAN/GuestUnmap                  = 1

    執行時機：Nested ESXi VM 開機完成後、VCF Installer 啟動前。

.PARAMETER Hosts
    ESXi 管理 IP 列表。預設讀取 inventory/lab.yaml 的 hosts[].mgmt_ip。

.PARAMETER User
    ESXi 登入帳號，預設 root。

.PARAMETER DryRun
    只顯示目前值，不套用變更。

.EXAMPLE
    .\Prepare-NestedESXi.ps1

.EXAMPLE
    .\Prepare-NestedESXi.ps1 -DryRun

.EXAMPLE
    .\Prepare-NestedESXi.ps1 -Hosts 10.0.1.14,10.0.1.15
#>

[CmdletBinding()]
param(
    [string[]] $Hosts = @('10.0.1.14','10.0.1.15','10.0.1.16','10.0.1.17'),
    [string]   $User  = 'root',
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'

# ============ Settings to apply ============
$SETTINGS = [ordered]@{
    '/LSOM/VSANDeviceMonitoring'       = 0   # 關閉裝置監控，避免 nested 環境誤判磁碟錯誤
    '/LSOM/lsomSlowDeviceUnmount'      = 0   # 關閉慢速磁碟偵測，nested 虛擬磁碟速度本來較慢
    '/VSAN/SwapThickProvisionDisabled' = 1   # 停用 swap thick provision，節省 nested 空間
    '/VSAN/Vsan2ZdomCompZstd'          = 0   # CPU 受限環境回退到 LZ4（不用 Zstd）
    '/VSAN/FakeSCSIReservations'       = 1   # 讓 nested vSAN 可在 physical vSAN 上正常運作
    '/VSAN/GuestUnmap'                 = 1   # 允許 TRIM/UNMAP 傳遞到底層 physical vSAN
}

# ============ Helpers ============
function Ensure-PowerCLI {
    $needed = 'VMware.VimAutomation.Core'
    if (-not (Get-Module -Name $needed)) {
        if (-not (Get-Module -ListAvailable -Name $needed)) {
            throw "$needed not installed. Run: Install-Module VMware.PowerCLI -Scope CurrentUser -Force"
        }
        try { Import-Module $needed -Global -DisableNameChecking -ErrorAction Stop | Out-Null }
        catch {
            if ($_.Exception.Message -match 'Assembly with same name is already loaded') {
                Write-Warning "PowerCLI already loaded, continuing."
            } else { throw }
        }
    }
    try {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false `
            -DefaultVIServerMode Single -Confirm:$false -Scope Session -ErrorAction Stop | Out-Null
    } catch { Write-Warning $_ }
}

Ensure-PowerCLI

# One credential prompt, shared across all hosts
$cred = Get-Credential -UserName $User -Message "ESXi root password (shared across all hosts)"

$rows = New-Object System.Collections.Generic.List[object]

foreach ($h in $Hosts) {
    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor Cyan
    Write-Host " $h" -ForegroundColor Cyan
    Write-Host "===================================================================" -ForegroundColor Cyan

    if ($global:DefaultVIServers -and $global:DefaultVIServers.Count -gt 0) {
        Disconnect-VIServer * -Force -Confirm:$false -ErrorAction SilentlyContinue
    }

    $vh = $null
    try {
        $vh      = Connect-VIServer -Server $h -Credential $cred -Force -ErrorAction Stop
        $esxiObj = Get-VMHost -Server $vh | Select-Object -First 1
        $cli     = Get-EsxCli -V2 -VMHost $esxiObj -Server $vh

        foreach ($opt in $SETTINGS.Keys) {
            $want = $SETTINGS[$opt]

            $listArgs        = $cli.system.settings.advanced.list.CreateArgs()
            $listArgs.option = $opt
            $current         = $null

            try {
                $cur     = $cli.system.settings.advanced.list.Invoke($listArgs) | Select-Object -First 1
                $current = $cur.IntValue
            } catch {
                Write-Warning "  read $opt failed: $_"
                $rows.Add([pscustomobject]@{
                    Host=$h; Option=$opt; Before='ERR'; Want=$want; After=''; Status='READ_FAIL'
                })
                continue
            }

            if ($DryRun) {
                Write-Host ("  [DRY] {0,-36}  {1}  ->  {2}" -f $opt, $current, $want)
                $rows.Add([pscustomobject]@{
                    Host=$h; Option=$opt; Before=$current; Want=$want; After=$current; Status='DRY_RUN'
                })
                continue
            }

            if ("$current" -eq "$want") {
                Write-Host ("  = {0,-36}  already = {1}" -f $opt, $current) -ForegroundColor DarkGray
                $rows.Add([pscustomobject]@{
                    Host=$h; Option=$opt; Before=$current; Want=$want; After=$current; Status='UNCHANGED'
                })
                continue
            }

            try {
                $setArgs          = $cli.system.settings.advanced.set.CreateArgs()
                $setArgs.option   = $opt
                $setArgs.intvalue = $want
                $cli.system.settings.advanced.set.Invoke($setArgs) | Out-Null

                $cur2  = $cli.system.settings.advanced.list.Invoke($listArgs) | Select-Object -First 1
                $after = $cur2.IntValue
                Write-Host ("  + {0,-36}  {1}  ->  {2}" -f $opt, $current, $after) -ForegroundColor Green
                $rows.Add([pscustomobject]@{
                    Host=$h; Option=$opt; Before=$current; Want=$want; After=$after; Status='UPDATED'
                })
            } catch {
                Write-Warning "  write $opt failed: $_"
                $rows.Add([pscustomobject]@{
                    Host=$h; Option=$opt; Before=$current; Want=$want; After=''; Status='WRITE_FAIL'
                })
            }
        }
    }
    catch {
        Write-Warning "[$h] connect/configure failed: $_"
        $rows.Add([pscustomobject]@{
            Host=$h; Option='(connect)'; Before=''; Want=''; After=''; Status="FAIL: $($_.Exception.Message)"
        })
    }
    finally {
        if ($vh -and $vh.IsConnected) {
            Disconnect-VIServer $vh -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

Write-Host ""
Write-Host "===================== RESULT =====================" -ForegroundColor Cyan
$rows | Format-Table Host, Option, Before, Want, After, Status -AutoSize

$csv = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) `
                 ("prepare-nestedESXi-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
$rows | Export-Csv -NoTypeInformation -Path $csv -Encoding UTF8
Write-Host "Log: $csv"
