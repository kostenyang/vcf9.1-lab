# poweron-all-stack.ps1 — 把 VCF 9.1 M02 管理域整套開回來(對應 shutdown-all-except-vc.ps1)。
# 依 VCF 官方啟動順序分層開機：vCenter(通常已開)→ NSX → SDDC Manager → Operations → Supervisor → VCFA。
# 走 inner vCenter REST power start，可由 SYSTEM 排程執行。
$ErrorActionPreference = 'Continue'
$log  = 'E:\9.1\poweron-all-stack.log'
$base = 'https://10.0.1.19'
$cred = 'administrator@vsphere.local:VMware1!VMware1!'
function Log($m){ "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Tee-Object -Append $log }

# 開機優先序：數字小的先開
function Tier($name){
  switch -Regex ($name){
    'vc01'                          { 0; break }   # vCenter(通常已開)
    'nsx'                           { 1; break }   # NSX Manager
    'vna'                           { 2; break }   # NSX VNA
    'sddcm'                         { 3; break }   # SDDC Manager
    'ops01|opsc01'                  { 4; break }   # VCF Operations
    'license'                       { 4; break }
    'vsp01|SupervisorControl|^flb'  { 5; break }   # Supervisor
    'auto-platform'                 { 6; break }   # VCFA
    default                         { 4 }
  }
}
# 每個 tier 開完後等待秒數(讓控制平面起來)
$tierWait = @{ 1=120; 2=60; 3=120; 4=90; 5=180; 6=0 }

Log "==== poweron-all-stack 開始 ===="
try {
  $sec = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cred))
  $sid = Invoke-RestMethod -Method Post -Uri "$base/api/session" -Headers @{Authorization="Basic $sec"} -SkipCertificateCheck -TimeoutSec 30
  $h = @{ 'vmware-api-session-id' = $sid }
  Log "連上 inner vCenter REST API"

  $all = Invoke-RestMethod -Uri "$base/api/vcenter/vm" -Headers $h -SkipCertificateCheck -TimeoutSec 30
  $ordered = $all | Select-Object *, @{n='t';e={ Tier $_.name }} | Sort-Object t, name

  $lastTier = $null
  foreach($v in $ordered){
    if($v.t -eq 0){ Log "略過(保留/vCenter) $($v.name) ($($v.power_state))"; continue }
    if($v.power_state -eq 'POWERED_ON'){ Log "已開機 [$($v.t)] $($v.name)"; continue }
    if($null -ne $lastTier -and $v.t -ne $lastTier){
      $w = $tierWait[$lastTier]; if($w){ Log "  -- tier $lastTier 開完，等 ${w}s --"; Start-Sleep -Seconds $w }
    }
    try {
      Invoke-RestMethod -Method Post -Uri "$base/api/vcenter/vm/$($v.vm)/power?action=start" -Headers $h -SkipCertificateCheck -TimeoutSec 30 | Out-Null
      Log "Power on [$($v.t)] $($v.name) [$($v.vm)]"
    } catch { Log "Power on 失敗 $($v.name): $($_.Exception.Message)" }
    $lastTier = $v.t
  }

  Start-Sleep -Seconds 20
  $all = Invoke-RestMethod -Uri "$base/api/vcenter/vm" -Headers $h -SkipCertificateCheck -TimeoutSec 30
  Log "---- 開機指令送出後狀態 ----"
  $all | Sort-Object name | ForEach-Object { Log ("  {0,-30} {1}" -f $_.name,$_.power_state) }
  Log "==== 完成(各服務 Ready 另需 20-40 分鐘) ===="
} catch {
  Log "錯誤: $($_.Exception.Message)"
}
