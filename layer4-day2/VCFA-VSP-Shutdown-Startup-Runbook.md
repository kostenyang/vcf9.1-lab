# VCFA + VSP 計畫性關機 / 開機 Runbook（省電用）

> 計畫性停機省電：只關 **VCFA（auto-platform）+ VSP（管理 supervisor / VCF Services Runtime）**，
> **vSphere / vSAN 叢集維持開著**（所以開機不必退 vSAN shutdown mode，簡單可靠）。
> 用 Windows 排程 + 腳本全自動，獨立於任何互動工具。

## 適用範圍與物件

| 項目 | 值 |
|---|---|
| 關機對象 | VCFA `auto-platform`（`vm-92`）+ VSP `vsp01`×4（`vm-34` 控制平面 / `vm-35/36/37` worker）|
| 不關 | vCenter `vcf-m02-vc01`(10.0.1.19) / ESXi / vSAN（保持開著）|
| 管理 API（VSP）| 任一 VSP 節點 `:5480`，本 lab 用 **10.0.0.222**（.221 也開）|
| 帳密 | vCenter `administrator@vsphere.local`、VSP API `vmware-system-user`、皆 `VMware1!VMware1!` |
| 腳本位置 | `E:\9.1\tools\`（非 repo，含密碼不入版控）|

## 為什麼不是純 Ops UI（照 KB 的程度）

官方 KB：VCFA 用 **VCF Operations UI** Power off、VSP 用 **KB 440874** 腳本
（`vcf_services_runtime_shutdown.sh`，**Broadcom Confidential，不可放公開 repo**，自 KB 下載放 `E:\9.1\`）。

本自動化：
- **VSP / VCF Services Runtime** → **真正用 KB 440874 官方腳本** 做協調式 drain
  （`POST /api/v1/system?action=shutdown`，scale down 所有 workload/controller + 建開機自動恢復標記）。
- **VCFA** → 用 vCenter guest OS 優雅關機（Ops UI 無法穩定自動化）。OS 層優雅，但非 Ops 的 app-drain。

## 前置工具（已備於 `E:\9.1\tools`）

- `jq.exe`(1.7.1)、`govc.exe`(0.54.1) — 官方腳本前置。git bash 需 `export PATH=/e/9.1/tools:$PATH`。
- ⚠️ 官方腳本的 `govc` 關 VM 段在 git bash 會踩 **`base64: invalid input`**（Windows jq.exe CRLF）。
  **解 = 加 `--skip-poweroff`**（官方 drain 照跑、避開 bug），VM 改用 vCenter API guest shutdown 自己關。

## 關機流程（`E:\9.1\tools\KB-Shutdown-VCFA-VSP.sh`）

1. **VCFA `vm-92` guest shutdown**（官方順序：VCFA 先），等 180s。
2. **官方 KB drain**：`TASK_TIMEOUT_SECONDS=2400 vcf_services_runtime_shutdown.sh --node-ip 10.0.0.222 --password ... --skip-poweroff`
   - ⚠️ **`TASK_TIMEOUT_SECONDS=2400` 必設** —— 預設 600s 在 nested lab **會逾時失敗**（見下方踩雷）。
3. **關 VSP 4 節點**：worker `vm-35/36/37` 先、控制平面 `vm-34` 最後，guest shutdown。
4. **驗證 + 硬關殘留**：等 150s 後逐台驗證，仍 `POWERED_ON` 的 **force stop**（`power?action=stop`）。
   - ⚠️ 必做 —— guest shutdown 可能回 HTTP 204 卻沒真的關（見下方踩雷）。

`TEST=1` 走 dry-run（官方腳本 `--dry-run`、不真的關），用來驗排程環境。log：`E:\9.1\tools\kb-shutdown.log`。

## 開機流程（`E:\9.1\tools\PowerOn-VCFA-VSP.ps1`）

反向依賴順序：
1. 先開 **VSP `vm-34/35/36/37`**。
2. **等 360s** 讓 supervisor 控制平面起來。
3. 再開 **VCFA `vm-92`**。
4. 回報電源狀態。VCFA 服務（prelude）開機後還要 ~15-20 分鐘才全 Ready。

> 即使官方 drain 沒完成標記，實測開機後 supervisor 仍會自行恢復（VCFA HTTP 200、4 節點 Ready）。

## 排程（Windows Task Scheduler，SYSTEM，跑 git bash / pwsh）

```powershell
# 關機（bash 腳本）
$bash='C:\Program Files\Git\bin\bash.exe'
Register-ScheduledTask -TaskName 'KB-Shutdown-VCFA-VSP-<date>' -User SYSTEM -RunLevel Highest -Force `
  -Action (New-ScheduledTaskAction -Execute $bash -Argument '-lc "bash /e/9.1/tools/KB-Shutdown-VCFA-VSP.sh"') `
  -Trigger (New-ScheduledTaskTrigger -Once -At '<yyyy-MM-dd> 20:00:00') `
  -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 60))

# 開機（pwsh 腳本）
$pwsh='C:\Program Files\PowerShell\7\pwsh.exe'
Register-ScheduledTask -TaskName 'VCFA-VSP-PowerOn-<date>' -User SYSTEM -RunLevel Highest -Force `
  -Action (New-ScheduledTaskAction -Execute $pwsh -Argument '-NoProfile -ExecutionPolicy Bypass -File "E:\9.1\tools\PowerOn-VCFA-VSP.ps1"') `
  -Trigger (New-ScheduledTaskTrigger -Once -At '<yyyy-MM-dd> 06:00:00')
```

> 部署前先用 `TEST=1` 跑一次 SYSTEM 排程驗證環境（不真的關）。一次性 trigger 跑完不再觸發。

## 踩過的雷（2026-06-18 首次正式跑）

1. **官方 drain 逾時**：drain task 跑 >600s 仍 Running → 腳本內建 600s timeout 撞線、`exit 1`。
   **根因 = nested lab 慢；解 = `TASK_TIMEOUT_SECONDS=2400`**。（首跑沒設 → drain 沒乾淨完成，VM 被後續步驟關掉。）
2. **`vm-35` guest shutdown 回 204 卻沒關**，一直開到 3 天後才發現。
   **解 = 步驟 4 驗證 + 硬關殘留**（已補進腳本）。

## 快速指令

```bash
# 手動關機（前景）
export PATH=/e/9.1/tools:$PATH
bash /e/9.1/tools/KB-Shutdown-VCFA-VSP.sh

# 驗證測試（不真的關）
TEST=1 bash /e/9.1/tools/KB-Shutdown-VCFA-VSP.sh

# 手動開機
pwsh -File E:\9.1\tools\PowerOn-VCFA-VSP.ps1

# 查電源
VC=vcf-m02-vc01.home.lab; TOK=$(curl -sk -u 'administrator@vsphere.local:VMware1!VMware1!' -X POST https://$VC/api/session|tr -d '"')
for vm in vm-92 vm-34 vm-35 vm-36 vm-37; do echo "$vm: $(curl -sk -H "vmware-api-session-id: $TOK" https://$VC/api/vcenter/vm/$vm/power)"; done
```
