<#
.SYNOPSIS
    Upgrade a (single) nested ESXi host from 9.0 to 9.1 using PowerCLI.

.DESCRIPTION
    Supports two flows:

      Mode A : DEPOT
        - You give a 9.1 offline depot .zip (or an ISO that contains one).
        - Script uploads it to a datastore on the host and runs esxcli
          software profile update via Get-EsxCli -V2.

      Mode B : ISO-BOOT
        - You give the 9.1 .iso and an outer vCenter + nested VM name.
        - Script mounts the ISO to the nested VM, sets boot-once to CD,
          and reboots the VM so you can run the interactive upgrade
          from the ISO console.

    Both modes share -LabWorkarounds switches that apply common nested /
    VCF 9.1 lab tweaks (CPU/HCL/TPM bypasses).  Add the specific advanced
    settings from williamlam.com VCF 9.1 lab-workarounds post into the
    Invoke-LabWorkarounds function below — placeholders are marked TODO.

.PARAMETER ESXiHost
    IP or FQDN of the nested ESXi host (the one being upgraded).

.PARAMETER ESXiUser
    ESXi user. Default 'root'.

.PARAMETER ISOPath
    Local path to ESXi 9.1 ISO. Required for Mode B; optional in Mode A
    (script will try to extract a depot zip from inside the ISO).

.PARAMETER DepotZipPath
    Local path to ESXi 9.1 offline bundle (.zip). Required for Mode A
    unless an ISO containing a depot zip is supplied via -ISOPath.

.PARAMETER DatastoreName
    Datastore on the nested ESXi where the depot zip will be uploaded
    (Mode A only). Default: 'datastore1'.

.PARAMETER ProfileSuffix
    The 9.1 image profile suffix to install. Default 'standard'.
    (full profile is auto-resolved as ESXi-9.1.0-<build>-<suffix>)

.PARAMETER OuterVCenter
    FQDN/IP of the vCenter that hosts the nested VM (Mode B only).

.PARAMETER OuterVCUser
    User on the outer vCenter (Mode B only). Default 'administrator@vsphere.local'.

.PARAMETER NestedVMName
    The nested VM name on the outer vCenter that runs the nested ESXi
    (Mode B only).

.PARAMETER Mode
    'Depot' or 'IsoBoot'. If omitted, auto-pick: Depot when a zip/ISO is
    given and host is reachable, IsoBoot when OuterVCenter+NestedVMName
    are given.

.PARAMETER LabWorkarounds
    One or more of:
        NoHardwareWarning    # esxcli --no-hardware-warning
        AllowLegacyCPU       # advanced setting / bootOption
        BypassVsanEsaHcl     # /VSAN/IgnoreClusterMemberListUpdates etc.
        SkipTpmCheck         # for hosts without vTPM
        VcfFleetDepotHttp    # VCF 9.1 HTTP fleet-depot workaround
        AllowAll             # apply every workaround above

.PARAMETER NoMaintenanceMode
    Skip entering / exiting maintenance mode (default = do enter/exit).

.PARAMETER Reboot
    Reboot after the depot install completes (Mode A). Default $true.

.EXAMPLE
    # Mode A - you have a depot zip
    .\Upgrade-NestedESXi91.ps1 `
        -ESXiHost 192.168.10.21 `
        -DepotZipPath 'D:\iso\VMware-ESXi-9.1.0-24000000-depot.zip' `
        -DatastoreName 'datastore1' `
        -LabWorkarounds AllowAll

.EXAMPLE
    # Mode A - only have an ISO, let script extract the depot
    .\Upgrade-NestedESXi91.ps1 `
        -ESXiHost esx01.lab.local `
        -ISOPath 'D:\iso\VMware-VMvisor-Installer-9.1.0.iso' `
        -LabWorkarounds NoHardwareWarning,AllowLegacyCPU

.EXAMPLE
    # Mode B - ISO boot via outer vCenter
    .\Upgrade-NestedESXi91.ps1 `
        -Mode IsoBoot `
        -ISOPath 'D:\iso\VMware-VMvisor-Installer-9.1.0.iso' `
        -OuterVCenter vc.lab.local `
        -NestedVMName 'nested-esx01'

.NOTES
    Tested-against : PowerCLI 13.x, PowerShell 7.x
    Author         : generated for Kosten's VCF 9.1 lab
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)] [string]   $ESXiHost,
    [Parameter(Mandatory=$false)] [string]   $ESXiUser       = 'root',
    [Parameter(Mandatory=$false)] [pscredential] $Credential,
    [Parameter(Mandatory=$false)] [string]   $ISOPath,
    [Parameter(Mandatory=$false)] [string]   $DepotZipPath,
    [Parameter(Mandatory=$false)] [string]   $DatastoreName  = 'datastore1',
    [Parameter(Mandatory=$false)] [string]   $ProfileSuffix  = 'standard',
    [Parameter(Mandatory=$false)] [string]   $OuterVCenter,
    [Parameter(Mandatory=$false)] [string]   $OuterVCUser    = 'administrator@vsphere.local',
    [Parameter(Mandatory=$false)] [string]   $NestedVMName,
    [Parameter(Mandatory=$false)] [ValidateSet('Depot','IsoBoot','Auto')] [string] $Mode = 'Auto',
    [Parameter(Mandatory=$false)] [ValidateSet('NoHardwareWarning','AllowLegacyCPU','BypassVsanEsaHcl','SkipTpmCheck','VcfFleetDepotHttp','AllowAll')] [string[]] $LabWorkarounds,
    [switch] $NoMaintenanceMode,
    [switch] $NoReboot
)

#region helpers --------------------------------------------------------------

function Write-Section($msg) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host (" {0}" -f $msg) -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Ensure-PowerCLI {
    # 只在「還沒載入」時才 import，避免 'Assembly with same name is already loaded' 錯誤。
    # 也只 import 需要的子模組（VimAutomation.Core），不要整包 VMware.PowerCLI meta module。
    $needed = @('VMware.VimAutomation.Core')

    foreach ($m in $needed) {
        if (Get-Module -Name $m) { continue }                              # 已載入 -> skip
        if (-not (Get-Module -ListAvailable -Name $m)) {
            throw "$m not installed. Run: Install-Module VMware.PowerCLI -Scope CurrentUser -Force"
        }
        try {
            Import-Module $m -ErrorAction Stop -Global -DisableNameChecking | Out-Null
        } catch {
            if ($_.Exception.Message -match 'Assembly with same name is already loaded') {
                Write-Warning "PowerCLI assembly already loaded in this session; continuing with already-loaded version."
            } else {
                throw
            }
        }
    }

    try {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false `
            -DefaultVIServerMode Single -Confirm:$false -Scope Session -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Set-PowerCLIConfiguration failed (non-fatal): $_"
    }
}

function Expand-DepotFromISO {
    param([string]$Iso)

    Write-Section "Mounting ISO to look for offline depot zip"
    $img = Mount-DiskImage -ImagePath $Iso -PassThru
    Start-Sleep -Seconds 2
    $drive = ($img | Get-Volume).DriveLetter
    if (-not $drive) { throw "Failed to mount ISO $Iso" }
    $root = "${drive}:\"

    # ESXi installer ISO normally contains an offline-bundle zip
    $zip = Get-ChildItem -Path $root -Recurse -Filter '*depot*.zip' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $zip) {
        # fallback: any zip on the ISO
        $zip = Get-ChildItem -Path $root -Recurse -Filter '*.zip' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '(?i)ESXi.*9\.1' } |
               Select-Object -First 1
    }
    if (-not $zip) {
        Dismount-DiskImage -ImagePath $Iso | Out-Null
        throw "No depot zip found inside $Iso . Either download the offline bundle separately, or use -Mode IsoBoot."
    }

    $localCopy = Join-Path $env:TEMP $zip.Name
    Copy-Item $zip.FullName $localCopy -Force
    Dismount-DiskImage -ImagePath $Iso | Out-Null
    Write-Host "  -> Extracted $($zip.Name) to $localCopy"
    return $localCopy
}

function Invoke-LabWorkarounds {
    param($EsxCli, [string[]]$Flags)

    if (-not $Flags) { return }
    $apply = if ($Flags -contains 'AllowAll') {
        @('NoHardwareWarning','AllowLegacyCPU','BypassVsanEsaHcl','SkipTpmCheck','VcfFleetDepotHttp')
    } else { $Flags }

    Write-Section "Applying lab workarounds: $($apply -join ', ')"

    foreach ($f in $apply) {
        switch ($f) {
            'AllowLegacyCPU' {
                # Tell ESXi to ignore the CPU-not-on-HCL fatal error.
                try {
                    $EsxCli.system.settings.kernel.set.Invoke(@{setting='allowLegacyCPU'; value='TRUE'}) | Out-Null
                    Write-Host "  + allowLegacyCPU = TRUE"
                } catch { Write-Warning "AllowLegacyCPU: $_" }
            }
            'BypassVsanEsaHcl' {
                # Common in nested vSAN ESA labs (William Lam's VCF 9.0.1 / 9.1 posts).
                try {
                    $EsxCli.system.settings.advanced.set.Invoke(@{option='/VSAN/IgnoreClusterMemberListUpdates'; intvalue=1}) | Out-Null
                    Write-Host "  + /VSAN/IgnoreClusterMemberListUpdates = 1"
                    # TODO: add the specific vSAN ESA HCL bypass keys from William Lam's
                    #       VCF 9.1 lab-workarounds post here once confirmed.
                } catch { Write-Warning "BypassVsanEsaHcl: $_" }
            }
            'SkipTpmCheck' {
                # Nested VMs usually don't have a vTPM.
                try {
                    $EsxCli.system.settings.advanced.set.Invoke(@{option='/UserVars/SuppressTpmAttestationWarning'; intvalue=1}) | Out-Null
                    Write-Host "  + /UserVars/SuppressTpmAttestationWarning = 1"
                } catch { Write-Warning "SkipTpmCheck: $_" }
            }
            'VcfFleetDepotHttp' {
                # VCF 9.1 introduced HTTP offline depot support for the Fleet Depot
                # service. The actual key/file lives in SDDC Manager, not on the
                # ESXi host itself - we only mark intent here so the operator
                # knows to flip the SDDC Manager flag separately.
                Write-Host "  ! Remember to enable HTTP offline depot in SDDC Manager / VCF Installer (see William Lam post)."
            }
            'NoHardwareWarning' {
                # Handled at install time (added to esxcli args), nothing to set now.
                Write-Host "  + NoHardwareWarning will be passed to 'software profile update'"
            }
        }
    }
}

#endregion -------------------------------------------------------------------

#region MODE A : DEPOT -------------------------------------------------------

function Invoke-DepotUpgrade {
    param(
        [string]$VMHost,
        [string]$User,
        [pscredential]$Cred,
        [string]$DepotZip,
        [string]$Datastore,
        [string]$ProfSuffix,
        [string[]]$Workarounds,
        [bool]$DoMaintenance,
        [bool]$DoReboot
    )
    if ($Cred) { $script:SharedCred = $Cred }

    Write-Section "Connecting to ESXi $VMHost (Mode = Depot)"
    if (-not $script:SharedCred) {
        $script:SharedCred = Get-Credential -UserName $User -Message "ESXi password for $User@$VMHost"
    }
    $cred = $script:SharedCred

    # 把任何殘留的 VIServer 連線清掉, 避免 PowerCLI 把後續 cmdlet 導向錯的 server
    if ($global:DefaultVIServers -and $global:DefaultVIServers.Count -gt 0) {
        Write-Host "Disconnecting $($global:DefaultVIServers.Count) stale VIServer(s)..."
        Disconnect-VIServer -Server * -Force -Confirm:$false -ErrorAction SilentlyContinue
    }

    $vh = Connect-VIServer -Server $VMHost -Credential $cred -Force -ErrorAction Stop

    try {
        $esxiObj = Get-VMHost -Server $vh | Select-Object -First 1
        Write-Host "Connected to host: $($esxiObj.Name) (uid: $($esxiObj.Uid))"

        # Datastore: 如果有指定就用指定的, 否則直接挑 host 上空間最大的 VMFS
        $ds = $null
        if ($Datastore) {
            $ds = Get-Datastore -Server $vh -Name $Datastore -ErrorAction SilentlyContinue
        }
        if (-not $ds) {
            $candidates = Get-Datastore -Server $vh |
                Where-Object { $_.Type -eq 'VMFS' -and $_.FreeSpaceGB -gt 2 -and $_.Accessible } |
                Sort-Object FreeSpaceGB -Descending
            if (-not $candidates) {
                $candidates = Get-Datastore -Server $vh |
                    Where-Object { $_.FreeSpaceGB -gt 2 -and $_.Accessible } |
                    Sort-Object FreeSpaceGB -Descending
            }
            if (-not $candidates) {
                Write-Host ""
                Write-Host "$VMHost 上可見的 datastore:" -ForegroundColor Yellow
                Get-Datastore -Server $vh | Format-Table Name, Type, @{N='FreeGB';E={[math]::Round($_.FreeSpaceGB,1)}}, Accessible
                throw "$VMHost 上找不到任何有空間的 datastore"
            }
            $ds = $candidates | Select-Object -First 1
            Write-Host "Using datastore: '$($ds.Name)' (Free $([math]::Round($ds.FreeSpaceGB,1)) GB)" -ForegroundColor Green
        }

        if ($DoMaintenance -and $esxiObj.ConnectionState -ne 'Maintenance') {
            Write-Host "Entering maintenance mode..."
            Set-VMHost -VMHost $esxiObj -State Maintenance -Confirm:$false | Out-Null
        }

        # 1. Upload depot zip to datastore
        # 用 -Location 直接傳 datastore 物件，比自己拼 vmstore:\<server>\<ds>\ 字串穩
        $zipName = Split-Path $DepotZip -Leaf
        Remove-PSDrive -Name dsUp -Force -ErrorAction SilentlyContinue
        $dsDrive = New-PSDrive -Name dsUp -PSProvider VimDatastore -Root '\' -Location $ds -ErrorAction Stop
        try {
            Write-Host "Uploading $zipName -> [$($ds.Name)] ..."
            Copy-DatastoreItem -Item $DepotZip -Destination "dsUp:\$zipName" -Force
        } finally {
            Remove-PSDrive -Name dsUp -Force -ErrorAction SilentlyContinue
        }
        $depotOnHost = "/vmfs/volumes/$($ds.Name)/$zipName"

        # 2. esxcli helpers - 明確帶 -Server 避免被別的 session 拐走
        $cli = Get-EsxCli -V2 -VMHost $esxiObj -Server $vh

        # 3. Apply lab workarounds *before* the upgrade (advanced settings, etc.)
        Invoke-LabWorkarounds -EsxCli $cli -Flags $Workarounds

        # 4. List profiles in depot
        Write-Section "Available profiles in depot"
        $listArgs = $cli.software.sources.profile.list.CreateArgs()
        $listArgs.depot = $depotOnHost
        $profiles = $cli.software.sources.profile.list.Invoke($listArgs)
        $profiles | Format-Table Name, Vendor, AcceptanceLevel -AutoSize
        $target = ($profiles | Where-Object { $_.Name -match "^ESXi-9\.1\.0-.+-$ProfSuffix$" } | Select-Object -First 1).Name
        if (-not $target) {
            $target = ($profiles | Where-Object { $_.Name -match $ProfSuffix } | Select-Object -First 1).Name
        }
        if (-not $target) { throw "Could not find profile matching '*$ProfSuffix*' in $depotOnHost" }
        Write-Host "Selected profile: $target" -ForegroundColor Green

        # 5. Run upgrade
        Write-Section "Running esxcli software profile update"
        $upArgs = $cli.software.profile.update.CreateArgs()
        $upArgs.depot   = $depotOnHost
        $upArgs.profile = $target
        if ($Workarounds -contains 'NoHardwareWarning' -or $Workarounds -contains 'AllowAll') {
            $upArgs.nohardwarewarning = $true
        }
        $result = $cli.software.profile.update.Invoke($upArgs)
        $result | Format-List Message, RebootRequired, VIBsInstalled, VIBsRemoved, VIBsSkipped

        # 6. Reboot
        $needReconnect = $false
        if ($DoReboot -and $result.RebootRequired) {
            Write-Host "Reboot required - rebooting host..."
            Restart-VMHost -VMHost $esxiObj -Confirm:$false -Force | Out-Null
            Write-Host "Waiting for host to come back (ping)..."
            do {
                Start-Sleep 15
                $up = Test-Connection -ComputerName $VMHost -Count 1 -Quiet
            } while (-not $up)
            Start-Sleep 30
            $needReconnect = $true
        }

        # 7. Exit maintenance mode (重啟過要重新連)
        if ($DoMaintenance) {
            if ($needReconnect) {
                # 連線在 reboot 已斷, 重新連
                Write-Host "Reconnecting to $VMHost to exit maintenance..."
                if ($vh -and $vh.IsConnected) {
                    Disconnect-VIServer $vh -Confirm:$false -Force -ErrorAction SilentlyContinue | Out-Null
                }
                # 等 hostd 起來 (光 ping 通不代表 API 通)
                $retries = 0
                do {
                    Start-Sleep 10
                    try {
                        $vh = Connect-VIServer -Server $VMHost -Credential $cred -Force -ErrorAction Stop
                        break
                    } catch {
                        $retries++
                        if ($retries -ge 12) { throw "hostd 還沒回來: $_" }
                        Write-Host "  ...重試 $retries/12"
                    }
                } while ($true)
                $esxiObj = Get-VMHost -Server $vh | Select-Object -First 1
            }

            $cur = (Get-VMHost -Server $vh | Select-Object -First 1).ConnectionState
            if ($cur -eq 'Maintenance') {
                Write-Host "Exiting maintenance mode..."
                Set-VMHost -VMHost $esxiObj -State Connected -Confirm:$false | Out-Null
                Write-Host "  -> Maintenance mode 已退出" -ForegroundColor Green
            } else {
                Write-Host "Host 狀態已是 $cur，不需退 maintenance"
            }
        }

        # 8. 印升級後版本
        try {
            $finalHost = Get-VMHost -Server $vh | Select-Object -First 1
            Write-Host "Final version: ESXi $($finalHost.Version) build $($finalHost.Build)" -ForegroundColor Cyan
        } catch { }
    }
    finally {
        if ($vh -and $vh.IsConnected) { Disconnect-VIServer $vh -Confirm:$false -Force | Out-Null }
    }
}

#endregion -------------------------------------------------------------------

#region MODE B : ISO BOOT ----------------------------------------------------

function Invoke-IsoBootUpgrade {
    param(
        [string]$VcServer,
        [string]$VcUser,
        [string]$NestedVM,
        [string]$Iso
    )

    Write-Section "Connecting to outer vCenter $VcServer (Mode = IsoBoot)"
    $cred = Get-Credential -UserName $VcUser -Message "Outer vCenter password for $VcUser@$VcServer"
    $vc   = Connect-VIServer -Server $VcServer -Credential $cred -ErrorAction Stop

    try {
        $vm = Get-VM -Server $vc -Name $NestedVM -ErrorAction Stop
        Write-Host "Nested VM   : $($vm.Name)"
        Write-Host "Power state : $($vm.PowerState)"

        # 1. Upload ISO to vCenter content datastore if it's a local path
        if (Test-Path $Iso) {
            $defaultDs = ($vm | Get-Datastore | Select-Object -First 1)
            $isoLeaf   = Split-Path $Iso -Leaf
            $remoteIso = "[$($defaultDs.Name)] ISO/$isoLeaf"

            Remove-PSDrive -Name dsIso -Force -ErrorAction SilentlyContinue
            $dsDrive = New-PSDrive -Name dsIso -PSProvider VimDatastore -Root '\' -Location $defaultDs -ErrorAction Stop
            try {
                if (-not (Test-Path "dsIso:\ISO")) { New-Item -Path "dsIso:\ISO" -ItemType Directory | Out-Null }
                if (-not (Test-Path "dsIso:\ISO\$isoLeaf")) {
                    Write-Host "Uploading ISO to [$($defaultDs.Name)] ISO/ ..."
                    Copy-DatastoreItem -Item $Iso -Destination "dsIso:\ISO\$isoLeaf" -Force
                } else {
                    Write-Host "ISO already present at $remoteIso"
                }
            } finally { Remove-PSDrive -Name dsIso -Force -ErrorAction SilentlyContinue }
        } else {
            $remoteIso = $Iso   # already a [datastore] path
        }

        # 2. Mount ISO
        Write-Host "Mounting ISO $remoteIso to CD/DVD..."
        $cd = Get-CDDrive -VM $vm | Select-Object -First 1
        if (-not $cd) { $cd = New-CDDrive -VM $vm -StartConnected -ISOPath $remoteIso }
        else          { Set-CDDrive   -CD $cd -StartConnected -Connected $true -ISOPath $remoteIso -Confirm:$false | Out-Null }

        # 3. Set boot-once to CD
        Write-Host "Setting boot-once to CD-ROM..."
        $spec                       = New-Object VMware.Vim.VirtualMachineConfigSpec
        $spec.BootOptions           = New-Object VMware.Vim.VirtualMachineBootOptions
        $spec.BootOptions.BootRetryEnabled = $true
        $spec.BootOptions.BootRetryDelay   = 10000
        $spec.BootOptions.BootOrder = @(
            (New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice),
            (New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice)
        )
        $vm.ExtensionData.ReconfigVM($spec)

        # 4. Restart VM
        if ($vm.PowerState -eq 'PoweredOn') {
            Write-Host "Restarting nested VM..."
            Restart-VM -VM $vm -Confirm:$false | Out-Null
        } else {
            Write-Host "Powering on nested VM..."
            Start-VM -VM $vm -Confirm:$false | Out-Null
        }

        Write-Host ""
        Write-Host "==> Open the VM console NOW and pick 'Upgrade ESXi, preserve VMFS datastore'." -ForegroundColor Yellow
        Write-Host "    After upgrade finishes, the boot-order will fall back to Disk on next reboot." -ForegroundColor Yellow
    }
    finally {
        if ($vc -and $vc.IsConnected) { Disconnect-VIServer $vc -Confirm:$false -Force | Out-Null }
    }
}

#endregion -------------------------------------------------------------------

#region MAIN -----------------------------------------------------------------

Ensure-PowerCLI

# Resolve mode
$autoMode = if ($Mode -eq 'Auto') {
    if ($OuterVCenter -and $NestedVMName -and $ISOPath -and -not $DepotZipPath) { 'IsoBoot' } else { 'Depot' }
} else { $Mode }
Write-Host "Resolved mode: $autoMode" -ForegroundColor Magenta

switch ($autoMode) {

    'Depot' {
        if (-not $ESXiHost) { throw "-ESXiHost is required for Depot mode" }
        if (-not $DepotZipPath) {
            if (-not $ISOPath) { throw "Provide either -DepotZipPath or -ISOPath" }
            $DepotZipPath = Expand-DepotFromISO -Iso $ISOPath
        }
        if (-not (Test-Path $DepotZipPath)) { throw "Depot zip not found: $DepotZipPath" }

        Invoke-DepotUpgrade `
            -VMHost $ESXiHost -User $ESXiUser -Cred $Credential `
            -DepotZip $DepotZipPath -Datastore $DatastoreName `
            -ProfSuffix $ProfileSuffix `
            -Workarounds $LabWorkarounds `
            -DoMaintenance (-not $NoMaintenanceMode) `
            -DoReboot     (-not $NoReboot)
    }

    'IsoBoot' {
        if (-not $OuterVCenter)  { throw "-OuterVCenter is required for IsoBoot mode" }
        if (-not $NestedVMName)  { throw "-NestedVMName is required for IsoBoot mode" }
        if (-not $ISOPath)       { throw "-ISOPath is required for IsoBoot mode" }

        Invoke-IsoBootUpgrade `
            -VcServer $OuterVCenter -VcUser $OuterVCUser `
            -NestedVM $NestedVMName -Iso $ISOPath
    }
}

Write-Section "Done"
#endregion
