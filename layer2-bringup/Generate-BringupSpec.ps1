<#
.SYNOPSIS
    讀 inventory/lab.yaml + 解密 secrets/lab.yaml, 套用 vcf91-bringup.template.json,
    輸出可以直接 POST 到 VCF Installer 的 bring-up spec JSON.

.PARAMETER InventoryFile
    inventory/lab.yaml 路徑. 預設自動找 repo root.

.PARAMETER TemplateFile
    JSON template. 預設同目錄的 vcf91-bringup.template.json.

.PARAMETER OutputFile
    輸出的填好 JSON. 預設 ./generated-bringup.json (在 .gitignore 裡, 不會進 git).

.PARAMETER LabMode
    啟用 lab workaround (vSAN ESA HCL bypass, skip nested CPU 檢查 等).

.PARAMETER SecretsAlreadyLoaded
    如果你已經 source scripts/load-secrets.sh, 加這個就不會再嘗試解密.

.EXAMPLE
    # 在 Linux automation host 上
    source ../scripts/load-secrets.sh
    pwsh ./Generate-BringupSpec.ps1 -SecretsAlreadyLoaded -LabMode

.NOTES
    Template 用 {{ var.path }} 與 | filter 來表達取值, 這支腳本實作:
      - {{ a.b.c }}           取 yaml/env 巢狀值
      - {{ list[0].field }}   取陣列元素
      - | default 'x'         取不到時的預設
      - | splitDot 0          按 '.' 切後取第 N 段 (拿 hostname 不要 FQDN)
#>

[CmdletBinding()]
param(
    [string] $InventoryFile,
    [string] $TemplateFile,
    [string] $OutputFile = './generated-bringup.json',
    [switch] $LabMode,
    [switch] $SecretsAlreadyLoaded
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not $InventoryFile) { $InventoryFile = Join-Path $repoRoot 'inventory/lab.yaml' }
if (-not $TemplateFile)  { $TemplateFile  = Join-Path $here    'vcf91-bringup.template.json' }

if (-not (Test-Path $InventoryFile)) { throw "inventory 找不到: $InventoryFile" }
if (-not (Test-Path $TemplateFile))  { throw "template 找不到: $TemplateFile" }

#--- 載入 powershell-yaml (沒裝就裝) ---------------------------------------
if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Write-Host "首次執行, 安裝 powershell-yaml..."
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml

#--- 讀 inventory ----------------------------------------------------------
$inv = Get-Content -Raw $InventoryFile | ConvertFrom-Yaml

#--- 讀 secrets ------------------------------------------------------------
$secrets = @{}
if ($SecretsAlreadyLoaded) {
    Write-Host "Secrets 從 env var 讀取..."
    $secrets = @{
        esxi             = @{ root_pw         = $env:ESXI_ROOT_PW }
        outer_vcenter    = @{ sso_admin_pw    = $env:OUTER_VC_SSO_PW }
        inner_vcenter    = @{ sso_admin_pw    = $env:INNER_VC_SSO_PW }
        sddc_manager     = @{ admin_pw        = $env:SDDC_ADMIN_PW; root_pw = $env:SDDC_ROOT_PW }
        nsx              = @{ admin_pw        = $env:NSX_ADMIN_PW }
        deploy_defaults  = @{ vm_root_pw      = $env:VM_ROOT_PW }
    }
    foreach ($k1 in $secrets.Keys) {
        foreach ($k2 in $secrets[$k1].Keys) {
            if (-not $secrets[$k1][$k2]) { throw "Env 缺值: $k1.$k2 (沒 source load-secrets.sh ?)" }
        }
    }
} else {
    $secretsFile = Join-Path $repoRoot 'inventory/secrets/lab.yaml'
    if (-not (Test-Path $secretsFile)) {
        throw "Secrets 檔不存在: $secretsFile`n請先 cp lab.example.yaml lab.yaml, 填值, 再 sops -e -i lab.yaml"
    }
    # 透過 sops 解密
    if (-not (Get-Command sops -ErrorAction SilentlyContinue)) {
        throw "需要 sops, 或加 -SecretsAlreadyLoaded 並 source load-secrets.sh"
    }
    $secrets = (sops -d $secretsFile) -join "`n" | ConvertFrom-Yaml
}

#--- Template engine ------------------------------------------------------

function Get-DeepValue {
    param($Obj, [string]$Path)
    $cur = $Obj
    # 把 "hosts[0].mgmt_ip" 拆成 [ 'hosts', '0', 'mgmt_ip' ]
    $parts = $Path -split '\.|\[|\]' | Where-Object { $_ -ne '' }
    foreach ($p in $parts) {
        if ($null -eq $cur) { return $null }
        if ($p -match '^\d+$') {
            $cur = @($cur)[[int]$p]
        } else {
            if ($cur -is [hashtable])      { $cur = $cur[$p] }
            elseif ($cur -is [array])      { return $null }
            else                           { $cur = $cur.$p }
        }
    }
    return $cur
}

function Resolve-Token {
    param([string]$Token, [hashtable]$Ctx)

    # "path | filter args | filter args"
    $segments = ($Token -split '\|').ForEach({ $_.Trim() })
    $path     = $segments[0]
    $val      = Get-DeepValue -Obj $Ctx -Path $path

    for ($i=1; $i -lt $segments.Count; $i++) {
        $f = $segments[$i]
        if ($f -match "^default\s+'(.*)'$") {
            if ($null -eq $val -or "$val" -eq '') { $val = $matches[1] }
        }
        elseif ($f -match '^splitDot\s+(\d+)$') {
            if ($val) { $val = ($val -split '\.')[[int]$matches[1]] }
        }
        else {
            Write-Warning "未知 filter: $f"
        }
    }
    return $val
}

#--- 套用 template ---------------------------------------------------------
$ctx = @{
    lab     = $inv.lab
    infra   = $inv.infra
    vcf     = $inv.vcf
    hosts   = $inv.hosts
    network = $inv.network
    secrets = $secrets
}

$rendered = Get-Content -Raw $TemplateFile
$rendered = [regex]::Replace($rendered, '\{\{\s*(.+?)\s*\}\}', {
    param($m)
    $v = Resolve-Token -Token $m.Groups[1].Value -Ctx $ctx
    if ($null -eq $v) { return '' }
    # JSON 安全 escape (數字 / bool 不要包雙引號 — 但 template 已經有 "..." 包覆, 所以這邊只處理字串內 escape)
    return ($v -replace '\\','\\\\' -replace '"','\\"')
}, 'IgnoreCase')

# 驗證能 parse 成 JSON
try {
    $parsed = $rendered | ConvertFrom-Json -Depth 30
} catch {
    Set-Content -Path "$OutputFile.broken.json" -Value $rendered -Encoding UTF8
    throw "渲染出來的 JSON parse 失敗, 結果已存 $OutputFile.broken.json. Error: $_"
}

#--- Lab workarounds ------------------------------------------------------
if ($LabMode) {
    Write-Host "套用 -LabMode workarounds..."
    if (-not $parsed.PSObject.Properties['skipChecks']) {
        $parsed | Add-Member -NotePropertyName skipChecks -NotePropertyValue @()
    }
    $parsed.skipChecks = @(
        'NESTED_CPU_CHECK',
        'NIC_COUNT_CHECK',
        'MIN_HOST_CHECK',
        'VSAN_ESA_HCL_CHECK',
        'ESX_THUMBPRINT_CHECK'
    )
    # vSAN ESA 在 nested 必要時關掉 (William Lam 9.1 lab post 的做法之一)
    if ($parsed.vsanSpec.esaConfig.enabled -eq $true) {
        Write-Host "  (留 vSAN ESA enabled = true, 改用 skipChecks 繞 HCL)"
    }
}

#--- 輸出 ------------------------------------------------------------------
$parsed | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputFile -Encoding UTF8
Write-Host ""
Write-Host "==> $OutputFile" -ForegroundColor Green
Write-Host "    $(((Get-Item $OutputFile).Length)/1KB) KB"
Write-Host ""
Write-Host "下一步: pwsh ./Submit-Bringup.ps1 -SpecFile $OutputFile -VcfInstaller https://<installer-ip>"
