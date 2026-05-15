# Scripts & Functions — Reference

整個 repo 所有可執行檔的功能對照表。跟各 layer 的 README 對應,這份只看「我要幹某件事該跑哪支」。

順序依 **執行流程** 排:`scripts/` 開機 → Layer 1 → 2 → 3 → 4,最後是 Inventory 與工作流。

> MCP server 已拆到獨立 repo:[github.com/kostenyang/mcp](https://github.com/kostenyang/mcp)。

---

## scripts/ — 共用 helper

位置: `scripts/`。跑在 automation host (10.0.0.65)。

| 腳本 | 功能 | 跑法 |
|---|---|---|
| `bootstrap-automation-host.sh` | 把一台 Ubuntu/Debian 變成 control plane: PowerCLI / Ansible / Terraform / pyvmomi + Docker + sops/age + gh CLI. 全步驟可重跑 | `LAB_USER=labops bash scripts/bootstrap-automation-host.sh` |
| `load-secrets.sh` | `source` 它會用 sops 解密 `inventory/secrets/lab.yaml`,把欄位 export 成 env var | `source scripts/load-secrets.sh` |

---

## Layer 1 — Nested ESXi 部署

位置: `layer1-nested/`。把 4 台 nested ESXi 開到外層 vCenter,並在 VCF Installer 啟動前完成預備設定。

| 檔案 | 功能 | 跑法 |
|---|---|---|
| `Prepare-NestedESXi.ps1` | 對 nested ESXi 套用 6 個 vSAN/LSOM lab advanced settings (idempotent). `-DryRun` 只看不改,`-Hosts` 指定特定 host | `pwsh Prepare-NestedESXi.ps1 [-DryRun] [-Hosts 10.0.1.14,...]` |

### Prepare-NestedESXi 套用的 6 個 setting

| Option | Value | 用途 |
|---|---|---|
| `/LSOM/VSANDeviceMonitoring` | 0 | 關 device monitoring (nested 假硬碟誤報) |
| `/LSOM/lsomSlowDeviceUnmount` | 0 | 關 slow device 自動 unmount |
| `/VSAN/SwapThickProvisionDisabled` | 1 | 允許 thin swap (nested 空間吃緊) |
| `/VSAN/Vsan2ZdomCompZstd` | 0 | 關 zstd 壓縮 (nested CPU 不夠力,回退 LZ4) |
| `/VSAN/FakeSCSIReservations` | 1 | 讓 nested vSAN 可在 physical vSAN 上正常運作 (必要) |
| `/VSAN/GuestUnmap` | 1 | 開 guest unmap (TRIM/UNMAP 傳到底層 physical vSAN) |

> 跟 Layer 4 的 `Apply-NestedVsanWorkarounds.ps1` 套的是同一組 6 個 setting,差別只在時機(部署前 vs day-2)。

---

## Layer 2 — VCF 9.1 Auto Bring-up

位置: `layer2-bringup/`。把 VCF Installer 接到 4 台 nested ESXi,自動 bring up Management Domain。

| 檔案 | 功能 | 跑法 |
|---|---|---|
| `vcf91-bringup.template.json` | VCF Installer JSON template, 用 `{{ var.path \| filter }}` 從 inventory 取值 | 不直接編輯 |
| `Generate-BringupSpec.ps1` | 讀 inventory + sops 自解密 secrets, 渲染 template -> `generated-bringup.json`. 支援 `-LabMode` 注入 skipChecks | `pwsh Generate-BringupSpec.ps1 -LabMode` |
| `Submit-Bringup.ps1` | 推 JSON 給 VCF Installer API. 先 validation 再 bring-up, 每 60 秒 poll | `pwsh Submit-Bringup.ps1 -VcfInstaller https://<x> -SpecFile <json>` |
| `New-VcfLab.ps1` | 一鍵 wrapper: 產 spec -> validate -> 你打 YES -> bring-up + poll | `pwsh New-VcfLab.ps1 -VcfInstaller https://<x>` |

> Layer 2 腳本會自己呼叫 sops 解密 secrets,**不需要** 先 `source load-secrets.sh`。

### -LabMode 預設注入的 skipChecks

`NESTED_CPU_CHECK`, `NIC_COUNT_CHECK`, `MIN_HOST_CHECK`, `VSAN_ESA_HCL_CHECK`, `ESX_THUMBPRINT_CHECK`

(正式環境加 `-SkipLabMode` 不要跳)

### Lab workaround 文件

| 檔案 | 內容 |
|---|---|
| `timeout-tuning.md` | 調大 VCF Installer / SDDC Manager `domainmanager` 的 timeout 參數,避免慢速 lab 的 OVF 佈署 / 服務啟動超時 |
| `timeout-tuning-operations-log.md` | 上述調整的實際操作指令(含不能直接 root SSH 時的 `pty + su` 取得 root 方法) |

---

## Layer 3 — Post bring-up

位置: `layer3-postbringup/`。Bring-up 完之後的 SDDC Manager 動作。**尚未實作**,以下為規劃。

| 預計檔案 | 功能 |
|---|---|
| `Commission-Hosts.ps1` | 把多餘 ESXi 加進 SDDC Manager 的 host pool |
| `New-WorkloadDomain.ps1` | 建第二個 workload domain |
| `Deploy-NsxEdge.ps1` | 自動 deploy NSX edge cluster |

---

## Layer 4 — Day-2 Ops

位置: `layer4-day2/`。跑現有環境的補丁/升級/維運,不負責 bring-up。

| 腳本 | 功能 | 跑法 |
|---|---|---|
| `Upgrade-NestedESXi91.ps1` | 單台升級主腳本 (Depot 模式: esxcli software profile update). 自動進/退 maintenance, reboot 後重連 + 印版本 | 不直接跑, 由 wrapper 呼叫 |
| `Run-BatchUpgrade.ps1` | 4 台批次升級 (depot 模式). 掃 `E:\9.1\` 找 depot zip; 共用一次密碼; 產 CSV log | `pwsh Run-BatchUpgrade.ps1` |
| `Run-BatchIsoBoot.ps1` | 4 台批次升級 (ISO 模式). 透過外層 vCenter 給 4 台掛 ISO 重開 | `pwsh Run-BatchIsoBoot.ps1` |
| `Exit-MaintenanceMode-All.ps1` | 4 台一鍵退 maintenance, 順便當「fleet 版本檢查表」 | `pwsh Exit-MaintenanceMode-All.ps1` |
| `Apply-NestedVsanWorkarounds.ps1` | 套 6 個 vSAN/LSOM lab workaround advanced settings (idempotent, 同 Layer 1 那組) | `pwsh Apply-NestedVsanWorkarounds.ps1 [-DryRun]` |
| `ESXi91-ISO-Upgrade-Steps.md` | Console 互動升級步驟 + CPU/HCL/TPM workaround 對照 (文件, 不可執行) | 參考文件 |
| `Troubleshoot-VsanPartition.md` | vSAN cluster partition 完整除錯流程 (unicast peer list 空) | 參考文件 |

---

## Inventory & Secrets

位置: `inventory/`

| 檔案 | 用途 |
|---|---|
| `lab.yaml` | lab 全部拓樸 (明文, 非敏感): outer vCenter / AD / 4 台 nested ESXi / network VLAN/CIDR / artifact 路徑 |
| `secrets/lab.example.yaml` | 密碼欄位範本. `cp lab.example.yaml lab.yaml` -> 填值 -> `sops -e -i lab.yaml` 加密 |
| `secrets/lab.yaml` | 實際密碼檔 (sops + age 加密後才 commit). 解密後的暫存檔被 `.gitignore` 擋掉 |

---

## 典型工作流 (從 4 台 9.0 nested 到 VCF 9.1 起來)

```
0. bootstrap automation host: bash scripts/bootstrap-automation-host.sh
1. push vcf9.1-lab 到 GitHub
2. 編 inventory/lab.yaml + sops 加密 inventory/secrets/lab.yaml
3. Layer 1/4 — 對 4 台 nested ESXi (在執行機器上, 要有 PowerCLI 13):
   pwsh .\layer4-day2\Run-BatchUpgrade.ps1               # 升 9.1
   pwsh .\layer1-nested\Prepare-NestedESXi.ps1           # vSAN/LSOM lab workaround
4. Layer 2 — VCF bring-up:
   pwsh .\layer2-bringup\New-VcfLab.ps1 -VcfInstaller https://<installer>
   - 先 validation, 看哪些欄位不對 (William Lam 9.1 schema 對齊)
   - 過了打 YES 真的 bring-up
   - 慢速 lab 記得先做 layer2-bringup/timeout-tuning.md 的 timeout 調整
5. Layer 3 (TODO) — postbringup commission / domain / NSX
```

---

## 各 Layer 狀態

| Layer | 狀態 | 內容 |
|---|---|---|
| 1 Nested infra | 部分 | `Prepare-NestedESXi.ps1` (advanced settings) ready;`Deploy-NestedESXi.ps1` 待補 |
| 2 VCF Bring-up | scaffold | template/generator/submitter ready,等 9.1 OpenAPI 對齊欄位;timeout workaround 已記錄 |
| 3 Post-bringup | TODO | SDDC Manager API: commission hosts / new workload domain / NSX edge |
| 4 Day-2 ops | ✅ | nested ESXi 9.0 → 9.1 升級 + vSAN/LSOM workaround 已實作 |

---

## 通用注意事項

- **PowerShell 7 (`pwsh`)** 跑, 不要 5.1 (中文字串編碼會壞)
- **PowerCLI 13.x**, 第一次跑會自動裝
- 所有 wrapper 都會跳一次 `Get-Credential` 共用 4 台密碼
- 每支批次腳本都會產 `*-yyyyMMdd-HHmmss.csv` log
- Idempotent: 已是目標狀態的 host/setting/VM 會 skip, 不會重複動作
