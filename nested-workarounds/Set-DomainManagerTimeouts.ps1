<#
.SYNOPSIS
    把 VCF domainmanager 的 VSP/LCM timeout 參數調大,並 restart domainmanager。
    套到 SDDC Manager 與 / 或 VCF Installer(預設兩台都套)。

.DESCRIPTION
    nested lab 用。眉角:nested vSAN 上 etcd 慢,VSP bootstrap / LCM 元件安裝會撐到
    domainmanager 預設 timeout / 重試上限(常見 "failed after 60 retries")就放棄。
    調大這些參數讓它「慢但能完成」。

    取 root 的方法(rtolab 實證):
    - root 不能直接 SSH;`vcf` 可登入但非完整 sudoer。
    - **Posh-SSH 對 Photon 的 KEX 常失敗 → 本腳本用 plink(PuTTY)**。
    - root 需 pty:`(sleep 2; echo <pw>) | script -qec "su - root -c '<cmd>'" /dev/null`

    參數預設值來源:William Lam VCF 9.1 workarounds + rtolab timeout-tuning。

.EXAMPLE
    pwsh ./Set-DomainManagerTimeouts.ps1 -Target 10.0.1.18,10.0.1.4
    pwsh ./Set-DomainManagerTimeouts.ps1 -Target 10.0.1.18 -RootPassword 'VMware1!VMware1!'
#>
[CmdletBinding()]
param(
    [string[]] $Target       = @('10.0.1.18','10.0.1.4'),  # SDDC Manager, VCF Installer
    [string]   $VcfUser      = 'vcf',
    [string]   $VcfPassword  = 'VMware1!VMware1!',
    [string]   $RootPassword = 'VMware1!VMware1!',
    [string]   $PlinkPath    = 'C:\Program Files\PuTTY\plink.exe',
    [hashtable] $Timeouts    = @{
        'vsp.bootstrap.task.timeout.minutes'              = 240
        'vsp.bootstrap.command.timeout.minutes'           = 200
        'vc.appliance.services.check.timeout.minutes'     = 240
        'orchestrator.task.retry.max'                     = 240
        'nsxt.manager.wait.minutes'                       = 180
        'edge.node.vm.creation.max.wait.minutes'          = 90
        'nsxt.alb.image.upload.retry.check.interval.seconds' = 90
    }
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $PlinkPath)) { throw "找不到 plink: $PlinkPath (裝 PuTTY 或用 -PlinkPath)" }

# 組 apply bash 腳本
$applyLines = @(
    '#!/bin/bash','set -e',
    'F=/etc/vmware/vcf/domainmanager/application.properties',
    'TS=$(date +%Y%m%d-%H%M%S); cp -p "$F" "$F.bak-$TS"; echo "Backup $F.bak-$TS"',
    'O=$(stat -c ''%U:%G'' "$F"); M=$(stat -c ''%a'' "$F")',
    'ap(){ k="$1"; v="$2"; if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$F"; then sed -i -E "s|^[[:space:]]*${k}[[:space:]]*=.*|${k}=${v}|" "$F"; echo "upd ${k}=${v}"; else echo "${k}=${v}" >> "$F"; echo "add ${k}=${v}"; fi; }',
    'grep -qF "# lab timeout workarounds" "$F" || printf ''\n# lab timeout workarounds\n'' >> "$F"'
)
foreach ($k in $Timeouts.Keys) { $applyLines += ('ap {0} {1}' -f $k, $Timeouts[$k]) }
$applyLines += @(
    'chown "$O" "$F"; chmod "$M" "$F"',
    'systemctl restart domainmanager; sleep 6; echo "domainmanager:"; systemctl is-active domainmanager'
)
$apply = ($applyLines -join "`n")
$run   = "(sleep 2; echo '$RootPassword') | script -qec ""su - root -c 'bash /tmp/dm_timeouts.sh'"" /dev/null"
$ab = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($apply))
$rb = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($run))

foreach ($t in $Target) {
    Write-Host "==================== $t ====================" -ForegroundColor Cyan
    # 1. 寫 scripts(順便接受/更新 host key:pipe 'y')
    "y" | & $PlinkPath -ssh -pw $VcfPassword "$VcfUser@$t" "echo $ab | base64 -d > /tmp/dm_timeouts.sh; echo $rb | base64 -d > /tmp/dm_run.sh; echo OK_WRITTEN" 2>&1 |
        Where-Object { $_ -match 'OK_WRITTEN|error|denied' } | ForEach-Object { Write-Host "  $_" }
    # 2. pty+su 執行
    & $PlinkPath -batch -ssh -pw $VcfPassword "$VcfUser@$t" "bash /tmp/dm_run.sh" 2>&1 | ForEach-Object { Write-Host "  $_" }
}
Write-Host "`n完成。" -ForegroundColor Green
