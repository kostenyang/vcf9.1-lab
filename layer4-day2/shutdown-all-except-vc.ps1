# shutdown-all-except-vc.ps1 — 把 VCF 9.1 M02 管理域關到「只剩 vCenter」，其餘全部優雅關機。
# 走 inner vCenter REST guest shutdown，依 VCF 官方反向依賴順序分層關，最後驗證+補硬關殘留。
# vCenter(vc01) 保留開機；nested ESXi host 不動(那是 host 不是本清單的 VM)。
# 可由 SYSTEM 排程執行(不需 PowerCLI / Windows 密碼)。
$ErrorActionPreference = 'Continue'
$log  = 'E:\9.1\shutdown-all-except-vc.log'
$base = 'https://10.0.1.19'
$cred = 'administrator@vsphere.local:VMware1!VMware1!'
$keepPattern = 'vc01'   # 要保留開機的 VM 名稱 regex
function Log($m){ "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Tee-Object -Append $log }

# 關機優先序：數字小的先關(solutions → NSX → SDDC Manager)
function Tier($name){
  switch -Regex ($name){
    'auto-platform'            { 1; break }   # VCFA
    'vsp01|SupervisorControl|^flb' { 2; break }   # Supervisor 控制平面 + LB
    'ops01|opsc01'             { 3; break }   # VCF Operations
    'license'                  { 4; break }
    'vna'                      { 5; break }   # NSX VNA
    'nsx'                      { 6; break }   # NSX Manager
    'sddcm'                    { 7; break }   # SDDC Manager
    default                    { 5 }
  }
}

Log "==== shutdown-all-except-vc 開始(保留 =/$keepPattern/)===="
try {
  $sec = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cred))
  $sid = Invoke-RestMethod -Method Post -Uri "$base/api/session" -Headers @{Authorization="Basic $sec"} -SkipCertificateCheck -TimeoutSec 30
  $h = @{ 'vmware-api-session-id' = $sid }
  Log "連上 inner vCenter REST API"

  $all = Invoke-RestMethod -Uri "$base/api/vcenter/vm" -Headers $h -SkipCertificateCheck -TimeoutSec 30
  $targets = $all | ?{ $_.name -notmatch $keepPattern } |
             Select-Object *, @{n='t';e={ Tier $_.name }} | Sort-Object t, name
  Log ("保留開機: " + (($all | ?{ $_.name -match $keepPattern }).name -join ', '))

  $lastTier = $null
  foreach($v in $targets){
    if($v.power_state -ne 'POWERED_ON'){ Log "已關/非開機 [$($v.t)] $($v.name) ($($v.power_state))"; continue }
    if($null -ne $lastTier -and $v.t -ne $lastTier){ Log "  -- tier $lastTier 送完，緩衝 60s --"; Start-Sleep -Seconds 60 }
    try {
      Invoke-RestMethod -Method Post -Uri "$base/api/vcenter/vm/$($v.vm)/guest/power?action=shutdown" -Headers $h -SkipCertificateCheck -TimeoutSec 30 | Out-Null
      Log "Guest shutdown [$($v.t)] $($v.name) [$($v.vm)]"
    } catch {
      Log "Guest shutdown 失敗 $($v.name): $($_.Exception.Message) → 稍後硬關"
    }
    $lastTier = $v.t
  }

  Log "所有 guest shutdown 已送出，等 180s 讓 OS 收尾..."
  Start-Sleep -Seconds 180

  # 驗證 + 補硬關殘留(guest shutdown 偶爾回 204 卻沒關)
  $sid = Invoke-RestMethod -Method Post -Uri "$base/api/session" -Headers @{Authorization="Basic $sec"} -SkipCertificateCheck -TimeoutSec 30
  $h = @{ 'vmware-api-session-id' = $sid }
  $all = Invoke-RestMethod -Uri "$base/api/vcenter/vm" -Headers $h -SkipCertificateCheck -TimeoutSec 30
  foreach($v in ($all | ?{ $_.name -notmatch $keepPattern } | Sort-Object name)){
    if($v.power_state -eq 'POWERED_ON'){
      Log "⚠ 仍 ON → 硬關 $($v.name) [$($v.vm)]"
      try { Invoke-RestMethod -Method Post -Uri "$base/api/vcenter/vm/$($v.vm)/power?action=stop" -Headers $h -SkipCertificateCheck -TimeoutSec 30 | Out-Null } catch { Log "硬關失敗 $($v.name): $($_.Exception.Message)" }
    }
  }

  Start-Sleep -Seconds 15
  $all = Invoke-RestMethod -Uri "$base/api/vcenter/vm" -Headers $h -SkipCertificateCheck -TimeoutSec 30
  Log "---- 最終狀態 ----"
  $all | Sort-Object name | ForEach-Object { Log ("  {0,-30} {1}" -f $_.name,$_.power_state) }
  Log "==== 完成 ===="
} catch {
  Log "錯誤: $($_.Exception.Message)"
}
