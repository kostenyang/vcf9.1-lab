<#
.SYNOPSIS
    把 10.0.1.14~17 4 台 nested ESXi 全部退出 maintenance mode。

.USAGE
    .\Exit-MaintenanceMode-All.ps1
    .\Exit-MaintenanceMode-All.ps1 -Hosts 10.0.1.16,10.0.1.17
#>

[CmdletBinding()]
param(
    [string[]] $Hosts = @('10.0.1.14','10.0.1.15','10.0.1.16','10.0.1.17'),
    [string]   $User  = 'root'
)

$ErrorActionPreference = 'Stop'

#--- Load PowerCLI -----------------------------------------------------
function Ensure-PowerCLI {
    $needed = 'VMware.VimAutomation.Core'
    if (-not (Get-Module -Name $needed)) {
        if (-not (Get-Module -ListAvailable -Name $needed)) {
            throw "$needed not installed. Run: Install-Module VMware.PowerCLI -Scope CurrentUser -Force"
        }
        try { Import-Module $needed -Global -DisableNameChecking -ErrorAction Stop | Out-Null }
        catch {
            if ($_.Exception.Message -match 'Assembly with same name is already loaded') {
                Write-Warning "PowerCLI 已載過, 繼續用."
            } else { throw }
        }
    }
    try {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false `
            -DefaultVIServerMode Single -Confirm:$false -Scope Session -ErrorAction Stop | Out-Null
    } catch { Write-Warning $_ }
}

Ensure-PowerCLI

# 統一輸入一次密碼
$cred = Get-Credential -UserName $User -Message "ESXi root 密碼 (4 台共用)"

$results = @()
foreach ($h in $Hosts) {
    Write-Host ""
    Write-Host "----- $h -----" -ForegroundColor Yellow

    # 清掉所有殘留連線
    if ($global:DefaultVIServers -and $global:DefaultVIServers.Count -gt 0) {
        Disconnect-VIServer * -Force -Confirm:$false -ErrorAction SilentlyContinue
    }

    try {
        $vh = Connect-VIServer -Server $h -Credential $cred -Force -ErrorAction Stop
        $vmhost = Get-VMHost -Server $vh | Select-Object -First 1

        Write-Host "  狀態: $($vmhost.ConnectionState)"
        if ($vmhost.ConnectionState -eq 'Maintenance') {
            Set-VMHost -VMHost $vmhost -State Connected -Confirm:$false | Out-Null
            $vmhost = Get-VMHost -Server $vh | Select-Object -First 1
            Write-Host "  -> 已退出 maintenance, 現在: $($vmhost.ConnectionState)" -ForegroundColor Green
            $status = 'Exited maintenance'
        } else {
            Write-Host "  -> 本來就不在 maintenance, 跳過" -ForegroundColor Gray
            $status = 'Already connected'
        }

        $results += [pscustomobject]@{ Host=$h; Status=$status; ESXiVersion=$vmhost.Version; Build=$vmhost.Build }
    }
    catch {
        Write-Warning "[$h] $_"
        $results += [pscustomobject]@{ Host=$h; Status="FAIL: $($_.Exception.Message)"; ESXiVersion=''; Build='' }
    }
    finally {
        if ($global:DefaultVIServers.Count -gt 0) {
            Disconnect-VIServer * -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "===================== 結果 =====================" -ForegroundColor Cyan
$results | Format-Table -AutoSize
