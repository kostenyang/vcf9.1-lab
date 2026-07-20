# VCF 9.1 (M02) 每日開關機自動化 Runbook

> 目的：**每晚自動把 VCF 9.1 管理域關到只剩 vCenter 以省電，每早自動整套開回來**。
> 環境：nested VCF 9.1 lab（inner vCenter = `10.0.1.19` / `vcf-m02-vc01.home.lab`）。
> 執行主機：`10.0.0.200`（本機，Windows Server + PowerShell 7）。
> 最後更新：2026-07-20

---

## 1. 一眼看懂

| 項目 | 內容 |
|------|------|
| 每晚 **01:00** | 全關到只剩 vCenter（`shutdown-all-except-vc.ps1`） |
| 每早 **07:00** | 整套按啟動順序開回來（`poweron-all-stack.ps1`） |
| 全程保留開機 | `vcf-m02-vc01`（vCenter） |
| 執行身分 | Windows 工作排程器，`SYSTEM`（不需人登入、不需 PowerCLI/Windows 密碼） |
| 連線方式 | inner vCenter REST API（`administrator@vsphere.local`） |
| 服務完全 Ready | 開機後約 **20–40 分鐘**（etcd/K8s/VCFA/NSX 陸續起） |

---

## 2. 排程任務（Windows Task Scheduler）

| 任務名稱 | 觸發 | 執行內容 |
|----------|------|----------|
| `VCF-M02-Nightly-Shutdown-AllExceptVC` | 每日 01:00 | `pwsh.exe -File E:\9.1\tools\shutdown-all-except-vc.ps1` |
| `VCF-M02-Morning-PowerOn-FullStack` | 每日 07:00 | `pwsh.exe -File E:\9.1\tools\poweron-all-stack.ps1` |

查詢排程狀態：
```powershell
Get-ScheduledTask | ?{ $_.TaskName -match 'VCF-M02' } | ForEach-Object {
  $i=Get-ScheduledTaskInfo -TaskName $_.TaskName
  "{0,-40} {1,-8} Last={2} Next={3}" -f $_.TaskName,$_.State,$i.LastRunTime,$i.NextRunTime
}
```

---

## 3. 元件清單與關/開順序

inner vCenter 管理域共 14 台 VM。關機依 **VCF 反向依賴順序**（solutions 先、基礎服務後），開機為其反向。

| Tier | 元件 | VM 名稱 | 關機序 | 開機序 |
|:----:|------|---------|:------:|:------:|
| — | **vCenter** | `vcf-m02-vc01` | **保留** | **保留(通常已開)** |
| 1 | VCFA (Automation) | `vcf-m02-auto-platform-*` | 1（先關） | 6（最後開） |
| 2 | Supervisor VSP | `vcf-m02-vsp01-*` ×4 | 2 | 5 |
| 2 | Supervisor 控制平面 | `SupervisorControlPlaneVM (1)`、`flb-vcf-m02-sup01 (1)` | ⚠ 見 §5 | — |
| 3 | VCF Operations | `vcf-m02-ops01`、`vcf-m02-opsc01` | 3 | 4 |
| 4 | License | `vcf-m02-license` | 4 | 4 |
| 5 | NSX VNA | `vcf-m02-vna01` | 5 | 2 |
| 6 | NSX Manager | `vcf-m02-nsx01a` | 6 | 1 |
| 7 | SDDC Manager | `vcf-m02-sddcm01` | 7（最後關） | 3 |

> **VM ID（moref）會隨 VM 重建而變，腳本一律用名稱動態解析，不寫死。**

---

## 4. 腳本說明（都在 `E:\9.1\tools\`）

### 4.1 關機 `shutdown-all-except-vc.ps1`
- 連 inner vCenter REST，取全部 VM，**保留名稱含 `vc01` 的**、其餘依 Tier 分層。
- 每台送 **guest 優雅關機**（`/guest/power?action=shutdown`，需 VMware Tools）。
- 分層間緩衝 60s；全部送完等 180s。
- **驗證 + 補硬關**：仍為 `POWERED_ON` 的改送 `power?action=stop`（防 guest shutdown 回 204 卻沒關）。
- log：`E:\9.1\shutdown-all-except-vc.log`

### 4.2 開機 `poweron-all-stack.ps1`
- 依啟動順序 NSX→VNA→SDDC Manager→Operations→Supervisor→VCFA 分層 `power?action=start`。
- 每層間等待（NSX/SDDCM 120s、Supervisor 180s…）讓控制平面起來。
- log：`E:\9.1\poweron-all-stack.log`

### 手動執行
```powershell
# 立刻關機
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File 'E:\9.1\tools\shutdown-all-except-vc.ps1'
# 立刻開機
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File 'E:\9.1\tools\poweron-all-stack.ps1'
# 或直接觸發排程
Start-ScheduledTask -TaskName 'VCF-M02-Nightly-Shutdown-AllExceptVC'
Start-ScheduledTask -TaskName 'VCF-M02-Morning-PowerOn-FullStack'
```

---

## 5. ⚠ 已知例外：2 台關不掉的 Supervisor 系統 VM

`SupervisorControlPlaneVM (1)` 與 `flb-vcf-m02-sup01 (1)` 是 **vSphere Supervisor（WCP）系統受管 VM**：
- guest shutdown → **HTTP 500**（無可回應的 VMware Tools）
- 硬關 `power?action=stop` → **HTTP 403 Forbidden**（vCenter 刻意保護，同 vCLS 機制）

vCenter 這條路關不掉它們；要真關只能繞到所在 nested ESXi host 用 host CLI（`vim-cmd vmsvc/power.off`），但 vCenter 本身也跑在同批 host 上、必須保持開機。
**決策（2026-07-19）：留著就好**（小型控制平面 VM，耗電有限，避免動到 Supervisor 狀態）。
→ 所以「只剩 vCenter」實際 = `vc01` + 這 2 台系統 VM。

---

## 6. 開機後驗證服務狀態

```powershell
# 各服務 web 端點（回 200/301/302/401/403 都代表服務起來了）
function Probe($n,$u){ try{ $c=(Invoke-WebRequest $u -SkipCertificateCheck -TimeoutSec 15 -MaximumRedirection 0 -SkipHttpErrorCheck).StatusCode }catch{ $c=$_.Exception.Message }; "{0,-14} {1}" -f $n,$c }
Probe 'vCenter'   'https://10.0.1.19/ui/'
Probe 'SDDCM'     'https://10.0.1.18/'
Probe 'NSX'       'https://10.0.1.21/login.jsp'
Probe 'Ops'       'https://10.0.1.22/'
```
```bash
# VCFA 走 Host-header 路由：直接打 IP 會 404，要帶 FQDN
curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: vcf-m02-auto-vip.home.lab' https://10.0.0.170/automation/   # 期望 200
# NSX 叢集健康
curl -sk -u 'admin:VMware1!VMware1!' https://10.0.1.21/api/v1/cluster/status | grep overall_status            # 期望 STABLE
```

**2026-07-20 07:00 開機後實測**：vCenter 200、SDDCM 301、NSX 200 + cluster **STABLE**、Ops 200、Ops Collector 403、VCFA `/automation/` 200 → **全部服務正常**。

---

## 7. 疑難排解

| 症狀 | 原因 / 處置 |
|------|------------|
| VCFA 打 IP 回 404 | 正常。ingress 走 Host header，要帶 `Host: vcf-m02-auto-vip.home.lab` 打 `/automation/` |
| 2 台 Supervisor VM 一直 ON | 正常（§5，403 保護，決定留著） |
| guest shutdown 回 204 卻沒關 | 腳本第 4 步會驗證後補硬關 |
| 開機後服務未就緒 | 正常，需 20–40 分鐘；先確認 vCenter 再逐一 probe |
| VM ID 對不上 | 腳本用名稱動態解析，不受影響；勿在別處寫死 moref |
| 排程沒跑 | 查 `Get-ScheduledTaskInfo` 的 `LastTaskResult`（0=成功）與對應 log |

---

## 8. 檔案位置

| 檔案 | 路徑 |
|------|------|
| 關機腳本 | `E:\9.1\tools\shutdown-all-except-vc.ps1` |
| 開機腳本 | `E:\9.1\tools\poweron-all-stack.ps1` |
| 關機 log | `E:\9.1\shutdown-all-except-vc.log` |
| 開機 log | `E:\9.1\poweron-all-stack.log` |
| 本文件 | `E:\9.1\tools\VCF-M02-開關機-Runbook.md` |

（另有 KB 官方 drain 版 wrapper `E:\9.1\tools\KB-Shutdown-VCFA-VSP.sh` 備用，走 KB 440874 協調式 drain；目前每日排程未使用。）

---

## 9. 變更歷史

| 日期 | 變更 |
|------|------|
| 2026-07-17 | 建立 VSP+VCFA-only 每日 01:00 關 / 07:00 開排程 |
| 2026-07-19 | 改為「全stack 關到只剩 vCenter」常態；新增本兩支腳本並取代舊排程；記錄 2 台 403 保護 VM |
| 2026-07-20 | 首次全stack 自動開機（07:00）成功、服務實測正常 |
