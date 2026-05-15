<#
.SYNOPSIS
    4 台 nested ESXi 從外層 vCenter 用 ISO Boot 方式啟動升級。

.DESCRIPTION
    - 連到外層 vCenter
    - 對 4 個 nested VM (vcf-m02-esx01-91 ~ esx04-91) 依序：
        * 把 9.1 ISO 上傳到 datastore 的 ISO/ 資料夾 (只上傳一次)
        * 掛 ISO 到 CD/DVD
        * 設定 boot-once 到 CD-ROM
        * Restart VM
    - 之後你到每台 VM 的 console 選 "Upgrade ESXi, preserve VMFS datastore"
    - 升級完手動把 CD disconnect、boot order 改回 Disk 即可

.PARAMETER OuterVCenter
    外層 vCenter FQDN 或 IP (必填)

.PARAMETER OuterVCUser
    外層 vCenter 帳號. 預設 administrator@vsphere.local

.PARAMETER NestedVMs
    nested VM 名稱陣列. 預設四台已內建.

.PARAMETER ISOPath
    本機 ISO 完整路徑. 預設 E:\9.1\VMware-VMvisor-Installer-9.1.0.0.25370933.x86_64.iso

.PARAMETER IsoFolderOnDs
    上傳到 datastore 的子資料夾, 預設 'ISO'

.PARAMETER Datastore
    要上傳 ISO 的 datastore 名稱. 不填的話自動挑 VM 第一個 datastore.

.PARAMETER Sequential
    依序處理 (預設). 加 -Parallel 可同時對 4 台 Restart (但 ISO 上傳還是一次).

.EXAMPLE
    .\Run-BatchIsoBoot.ps1 -OuterVCenter vcsa.lab.local
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]  [string]   $OuterVCenter,
    [Parameter(Mandatory=$false)] [string]   $OuterVCUser = 'administrator@vsphere.local',
    [Parameter(Mandatory=$false)] [string[]] $NestedVMs   = @(
        'vcf-m02-esx01-91',
        'vcf-m02-esx02-91',
        'vcf-m02-esx03-91',
        'vcf-m02-esx04-91'
    ),
    [Parameter(Mandatory=$false)] [string]   $ISOPath     = 'E:\9.1\VMware-VMvisor-Installer-9.1.0.0.25370933.x86_64.iso',
    [Parameter(Mandatory=$false)] [string]   $IsoFolderOnDs = 'ISO',
    [Parameter(Mandatory=$false)] [string]   $Datastore,
    [switch] $Parallel
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ISOPath)) { throw "ISO not found: $ISOPath" }

#--- Load PowerCLI (耐 assembly-conflict 版本) ----------------------------
function Ensure-PowerCLI {
    $needed = @('VMware.VimAutomation.Core')
    foreach ($m in $needed) {
        if (Get-Module -Name $m) { continue }
        if (-not (Get-Module -ListAvailable -Name $m)) {
            throw "$m 沒裝. 跑: Install-Module VMware.PowerCLI -Scope CurrentUser -Force"
        }
        try { Import-Module $m -ErrorAction Stop -Global -DisableNameChecking | Out-Null }
        catch {
            if ($_.Exception.Message -match 'Assembly with same name is already loaded') {
                Write-Warning "PowerCLI 已經載過了, 繼續用舊的."
            } else { throw }
        }
    }
    try {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore `
            -ParticipateInCEIP $false -Confirm:$false -Scope Session -ErrorAction Stop | Out-Null
    } catch { Write-Warning "Set-PowerCLIConfiguration: $_" }
}

Ensure-PowerCLI

#--- Connect outer vCenter ------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Connecting to outer vCenter $OuterVCenter" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
$cred = Get-Credential -UserName $OuterVCUser -Message "Outer vCenter password for $OuterVCUser"
$vc   = Connect-VIServer -Server $OuterVCenter -Credential $cred -ErrorAction Stop

$results = @()

try {
    #--- Resolve VMs ------------------------------------------------------
    $vms = foreach ($name in $NestedVMs) {
        try { Get-VM -Server $vc -Name $name -ErrorAction Stop }
        catch { Write-Warning "找不到 VM '$name', 略過"; $null }
    } | Where-Object { $_ }

    if (-not $vms) { throw "都找不到 nested VM, 結束." }

    #--- Decide datastore -------------------------------------------------
    if (-not $Datastore) {
        $ds = $vms[0] | Get-Datastore | Select-Object -First 1
        $Datastore = $ds.Name
    } else {
        $ds = Get-Datastore -Name $Datastore -Server $vc -ErrorAction Stop
    }
    Write-Host "Datastore for ISO : $($ds.Name)"

    #--- Upload ISO once --------------------------------------------------
    $isoLeaf = Split-Path $ISOPath -Leaf
    $remoteIso = "[$($ds.Name)] $IsoFolderOnDs/$isoLeaf"

    Remove-PSDrive -Name dsIso -Force -ErrorAction SilentlyContinue
    $dsDrive = New-PSDrive -Name dsIso -PSProvider VimDatastore -Root '\' -Location $ds -ErrorAction Stop
    try {
        if (-not (Test-Path "dsIso:\$IsoFolderOnDs")) {
            Write-Host "建立資料夾 [$($ds.Name)] $IsoFolderOnDs/"
            New-Item -Path "dsIso:\$IsoFolderOnDs" -ItemType Directory | Out-Null
        }
        if (-not (Test-Path "dsIso:\$IsoFolderOnDs\$isoLeaf")) {
            Write-Host "上傳 $isoLeaf -> [$($ds.Name)] $IsoFolderOnDs/  (約 1-2 GB, 慢慢等)"
            Copy-DatastoreItem -Item $ISOPath -Destination "dsIso:\$IsoFolderOnDs\$isoLeaf" -Force
        } else {
            Write-Host "ISO 已在 $remoteIso ，跳過上傳."
        }
    } finally { Remove-PSDrive dsIso -Force -ErrorAction SilentlyContinue }

    #--- 給每台 VM 換 ISO + boot-once + restart --------------------------
    foreach ($vm in $vms) {
        Write-Host ""
        Write-Host "----- $($vm.Name) -----" -ForegroundColor Yellow
        $start = Get-Date

        try {
            # 掛 ISO
            $cd = Get-CDDrive -VM $vm | Select-Object -First 1
            if (-not $cd) {
                $cd = New-CDDrive -VM $vm -IsoPath $remoteIso -StartConnected -Confirm:$false
            } else {
                Set-CDDrive -CD $cd -IsoPath $remoteIso -StartConnected -Connected $true -Confirm:$false | Out-Null
            }
            Write-Host "  ISO 已掛: $remoteIso"

            # boot-once 到 CD-ROM
            $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
            $spec.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
            $spec.BootOptions.BootRetryEnabled = $true
            $spec.BootOptions.BootRetryDelay   = 10000
            $spec.BootOptions.BootOrder = @(
                (New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice),
                (New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice)
            )
            $vm.ExtensionData.ReconfigVM($spec)
            Write-Host "  Boot order: CD-ROM -> Disk"

            # Restart / Power on
            $vmNow = Get-VM -Server $vc -Id $vm.Id   # refresh
            if ($vmNow.PowerState -eq 'PoweredOn') {
                if ($Parallel) {
                    Restart-VM -VM $vmNow -Confirm:$false -RunAsync | Out-Null
                    Write-Host "  Restart-VM (async)"
                } else {
                    Restart-VM -VM $vmNow -Confirm:$false | Out-Null
                    Write-Host "  Restart-VM 完成"
                }
            } else {
                Start-VM -VM $vmNow -Confirm:$false | Out-Null
                Write-Host "  Start-VM 完成"
            }

            $results += [pscustomobject]@{
                VM       = $vm.Name
                Status   = 'Boot to ISO 已下達, 去 console 跑 Upgrade'
                Duration = ((Get-Date) - $start).ToString('hh\:mm\:ss')
            }
        }
        catch {
            Write-Warning "[$($vm.Name)] 失敗: $_"
            $results += [pscustomobject]@{
                VM       = $vm.Name
                Status   = "FAIL: $($_.Exception.Message)"
                Duration = ((Get-Date) - $start).ToString('hh\:mm\:ss')
            }
        }
    }
}
finally {
    if ($vc -and $vc.IsConnected) { Disconnect-VIServer $vc -Confirm:$false -Force | Out-Null }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " 全部下達完成. 現在到每台 VM 的 console 跑互動升級:" -ForegroundColor Green
Write-Host "   1. F11 接受 EULA"
Write-Host "   2. 選 local disk"
Write-Host "   3. 選 'Upgrade ESXi, preserve VMFS datastore'"
Write-Host "   4. F11 開始, 完成後 Enter 重開"
Write-Host "   5. 重開後 ISO 會留著掛但 boot order fall back 到 Disk,"
Write-Host "      你進系統後可以把 CD disconnect."
Write-Host "============================================================" -ForegroundColor Green

$results | Format-Table -AutoSize
$results | Export-Csv -NoTypeInformation `
    -Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) `
                     ("batch-isoboot-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)))
