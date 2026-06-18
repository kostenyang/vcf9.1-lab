<#
.SYNOPSIS
    VCF 9.1 lab — 從 inventory/lab.yaml 自動建立/驗證所有 A + PTR DNS 記錄.
    跑在 DNS server (= jumpbox 10.0.0.200) 上, 需 Windows DnsServer 模組.

    整合自 vcf9-lab-automation 的 add-dns-m02.ps1 (建 A+PTR) + check-dns-m02.ps1 (驗證),
    改成 idempotent + inventory-driven: 已正確的 skip, 漂移的 update, 缺的 add.

.PARAMETER Verify
    只驗證 (forward A / reverse PTR / 重複 IP), 不改任何記錄. = 舊 check-dns.

.PARAMETER WhatIf
    試跑, 印出會做什麼但不真的改 DNS.

.EXAMPLE
    pwsh ./Set-DnsRecords.ps1            # 建/補齊所有記錄 (idempotent)
    pwsh ./Set-DnsRecords.ps1 -Verify    # 只檢查
    pwsh ./Set-DnsRecords.ps1 -WhatIf    # 看會動什麼

.NOTES
    A/PTR 來源 = inventory: vcf.management_domain 下所有 (xxx_fqdn,xxx_ip) 配對 + hosts[].
    Reverse zone 依 dns.reverse_zones 的 subnet 比對 (只有 mgmt 段 10.0.0/10.0.1 有反解).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Verify
)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')
$invFile  = Join-Path $repoRoot 'inventory/lab.yaml'
if (-not (Test-Path $invFile)) { throw "找不到 inventory: $invFile" }

if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Write-Host "安裝 powershell-yaml..."
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml

if (-not (Get-Command Get-DnsServerResourceRecord -ErrorAction SilentlyContinue)) {
    throw "找不到 DnsServer 模組 — 這支要在 DNS server (10.0.0.200) 上、以系統管理員身分跑。"
}

$inv  = Get-Content -Raw $invFile | ConvertFrom-Yaml
$zone = $inv.dns.forward_zone
$dnsServer = $inv.dns.server
$revZones  = $inv.dns.reverse_zones   # [{zone, subnet}]

Write-Host "DNS server : $dnsServer" -ForegroundColor Cyan
Write-Host "Forward    : $zone"
Write-Host "Reverse    : $(( $revZones | ForEach-Object { $_.zone }) -join ', ')"
Write-Host ""

# ---- 1. 從 inventory 收集所有 (fqdn, ip) 配對 ----------------------------
$records = [System.Collections.Generic.List[object]]::new()

function Add-Pair([string]$fqdn, [string]$ip) {
    if (-not $fqdn -or -not $ip) { return }
    # 只收本 zone 的 FQDN; 取 hostname (zone 前那段)
    if ($fqdn -notlike "*.$zone") { return }
    $name = $fqdn.Substring(0, $fqdn.Length - ".$zone".Length)
    $script:records.Add([pscustomobject]@{ Name = $name; FQDN = $fqdn; IP = "$ip" })
}

# 遞迴找 hashtable 裡所有 (<prefix>fqdn, <prefix>ip) 同前綴配對
function Collect-FromNode($node) {
    if ($node -is [System.Collections.IDictionary]) {
        foreach ($k in @($node.Keys)) {
            if ($k -match '(?i)fqdn$') {
                $prefix = $k -replace '(?i)fqdn$',''      # '' / 'vip_' / 'node_' / 'platform_'
                $ipKey  = ($prefix + 'ip')
                if ($node.Contains($ipKey)) { Add-Pair $node[$k] $node[$ipKey] }
            }
        }
        foreach ($v in $node.Values) { Collect-FromNode $v }
    }
    elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        foreach ($item in $node) { Collect-FromNode $item }
    }
}

Collect-FromNode $inv.vcf.management_domain
# hosts[] 用 mgmt_ip
foreach ($h in $inv.hosts) { Add-Pair $h.fqdn $h.mgmt_ip }

# 去重 (FQDN)
$records = $records | Sort-Object FQDN -Unique
Write-Host "從 inventory 收集到 $($records.Count) 筆 forward 記錄。" -ForegroundColor Cyan
Write-Host ""

function Get-RevZoneFor([string]$ip) {
    $o = $ip.Split('.')
    $first3 = "$($o[0]).$($o[1]).$($o[2])"
    foreach ($rz in $revZones) { if ($rz.subnet -eq $first3) { return $rz.zone } }
    return $null
}

# ---- 2. VERIFY 模式 ------------------------------------------------------
if ($Verify) {
    $issues = 0; $ipMap = @{}
    foreach ($r in ($records | Sort-Object Name)) {
        $fwd = (Resolve-DnsName $r.FQDN -Server $dnsServer -Type A -ErrorAction SilentlyContinue |
                Where-Object Type -eq 'A' | Select-Object -First 1 -Expand IPAddress)
        $fwdTag = if ($fwd -eq $r.IP) {'OK '} elseif ($fwd) {"ERR got $fwd"; $issues++} else {'--- missing'; $issues++}
        $rev = ''
        if (Get-RevZoneFor $r.IP) {
            $rev = (Resolve-DnsName $r.IP -Server $dnsServer -ErrorAction SilentlyContinue |
                    Where-Object Type -eq 'PTR' | Select-Object -First 1 -Expand NameHost)
        }
        $revTag = if (-not (Get-RevZoneFor $r.IP)) {'n/a'} elseif ($rev -like "*$($r.Name)*") {'OK '} elseif ($rev) {"ERR $rev"; $issues++} else {'--- missing'; $issues++}
        if ($ipMap.ContainsKey($r.IP)) { Write-Host "  *** DUP IP $($r.IP): $($r.Name) & $($ipMap[$r.IP])" -ForegroundColor Red; $issues++ } else { $ipMap[$r.IP]=$r.Name }
        Write-Host ("  {0,-22} {1,-13} Fwd[{2}] Rev[{3}]" -f $r.Name, $r.IP, $fwdTag, $revTag)
    }
    Write-Host ""
    if ($issues -eq 0) { Write-Host "ALL OK — $($records.Count) 筆全部正確。" -ForegroundColor Green }
    else { Write-Host "$issues 個問題。跑 (不帶 -Verify) 自動補齊。" -ForegroundColor Yellow }
    return
}

# ---- 3. 建立 / 補齊 (idempotent) ----------------------------------------
$added=0; $updated=0; $skipped=0
foreach ($r in ($records | Sort-Object Name)) {
    # --- A record ---
    $existing = Get-DnsServerResourceRecord -ZoneName $zone -Name $r.Name -RRType A -ErrorAction SilentlyContinue
    $curIp = $existing.RecordData.IPv4Address.IPAddressToString | Select-Object -First 1
    if ($curIp -eq $r.IP) {
        $skipped++
        Write-Host ("  skip  A   {0,-22} -> {1}" -f $r.FQDN, $r.IP) -ForegroundColor DarkGray
    } elseif ($existing) {
        if ($PSCmdlet.ShouldProcess("$($r.FQDN) -> $($r.IP)", "Update A (was $curIp)")) {
            Remove-DnsServerResourceRecord -ZoneName $zone -Name $r.Name -RRType A -Force
            Add-DnsServerResourceRecordA -ZoneName $zone -Name $r.Name -IPv4Address $r.IP -TimeToLive 01:00:00
        }
        $updated++; Write-Host ("  upd   A   {0,-22} {1} -> {2}" -f $r.FQDN, $curIp, $r.IP) -ForegroundColor Yellow
    } else {
        if ($PSCmdlet.ShouldProcess("$($r.FQDN) -> $($r.IP)", "Add A")) {
            Add-DnsServerResourceRecordA -ZoneName $zone -Name $r.Name -IPv4Address $r.IP -TimeToLive 01:00:00
        }
        $added++; Write-Host ("  add   A   {0,-22} -> {1}" -f $r.FQDN, $r.IP) -ForegroundColor Green
    }

    # --- PTR record (只有 mgmt 反解 zone 內的才建) ---
    $rz = Get-RevZoneFor $r.IP
    if ($rz) {
        $last = $r.IP.Split('.')[-1]
        $exPtr = Get-DnsServerResourceRecord -ZoneName $rz -Name $last -RRType Ptr -ErrorAction SilentlyContinue
        $curPtr = ($exPtr.RecordData.PtrDomainName | Select-Object -First 1)?.TrimEnd('.')
        if ($curPtr -eq $r.FQDN) {
            # ok, skip
        } elseif ($exPtr) {
            if ($PSCmdlet.ShouldProcess("$($r.IP) -> $($r.FQDN)", "Update PTR (was $curPtr)")) {
                Remove-DnsServerResourceRecord -ZoneName $rz -Name $last -RRType Ptr -Force
                Add-DnsServerResourceRecordPtr -ZoneName $rz -Name $last -PtrDomainName "$($r.FQDN)." -TimeToLive 01:00:00
            }
            Write-Host ("        PTR {0,-13} {1} -> {2}" -f $r.IP, $curPtr, $r.FQDN) -ForegroundColor Yellow
        } else {
            if ($PSCmdlet.ShouldProcess("$($r.IP) -> $($r.FQDN)", "Add PTR")) {
                Add-DnsServerResourceRecordPtr -ZoneName $rz -Name $last -PtrDomainName "$($r.FQDN)." -TimeToLive 01:00:00
            }
            Write-Host ("        PTR {0,-13} -> {1}" -f $r.IP, $r.FQDN) -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "完成: 新增 $added, 更新 $updated, 略過 $skipped (共 $($records.Count) 筆)。" -ForegroundColor Cyan
Write-Host "驗證: pwsh ./Set-DnsRecords.ps1 -Verify"
