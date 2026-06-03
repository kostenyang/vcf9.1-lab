# VCF 9 Lab — Infrastructure as Code

整個 VCF 9 lab 環境的「重建檔」。每層各自獨立、能重跑、不依賴某台機器的記憶。

> **快速查腳本**: [SCRIPTS.md](./SCRIPTS.md) — 所有可執行檔的功能對照表 + 典型工作流

## Layout

依執行流程分層,`scripts/` 開機後依序跑 Layer 1 → 4:

```
.
├── inventory/                  # 環境拓樸與密碼
│   ├── lab.yaml                #   主清單 (明文, 非敏感: IP/FQDN/VLAN/datastore)
│   └── secrets/                #   sops + age 加密過的密碼/憑證
├── scripts/                    # 共用 helper (跑在 automation host)
│   ├── bootstrap-automation-host.sh
│   └── load-secrets.sh
├── layer1-nested/              # Nested ESXi 部署 + 部署前準備
│   ├── Deploy-NestedESXi-And-Installer.ps1  # 4 台 nested ESXi + VCF Installer 一鍵 OVA 部署
│   └── Prepare-NestedESXi.ps1               # 套用 6 個 vSAN/LSOM advanced settings
├── layer2-bringup/             # VCF Installer JSON + 推送腳本
│   ├── New-VcfLab.ps1          #   一鍵 wrapper
│   ├── Generate-BringupSpec.ps1 / Submit-Bringup.ps1
│   ├── vcf91-bringup.template.json
│   └── timeout-tuning.md       #   慢速 lab 的 domainmanager timeout workaround
├── layer3-postbringup/         # SDDC Manager API: commission / workload domain / NSX (TODO)
│   └── vcf-operations-automation-deploy-troubleshooting.md  # M02 部署故障排除紀錄
├── layer4-day2/                # 升級 / 補丁 / vSAN workaround (PowerCLI)
│   ├── Run-BatchUpgrade.ps1 / Run-BatchIsoBoot.ps1
│   ├── Upgrade-NestedESXi91.ps1 / Exit-MaintenanceMode-All.ps1
│   ├── Apply-NestedVsanWorkarounds.ps1
│   └── ESXi91-ISO-Upgrade-Steps.md / Troubleshoot-VsanPartition.md
├── README.md                   # 本檔
└── SCRIPTS.md                  # 腳本功能對照表
```

> **MCP server 已拆到獨立 repo**: [github.com/kostenyang/mcp](https://github.com/kostenyang/mcp)
> (`mcp-server/` — FastMCP server，給 Claude Code/Desktop 呼叫本 lab 的操作 tool)。

## 各 Layer

| Layer | 狀態 | 內容 | README |
|---|---|---|---|
| 1 Nested infra | ✅ | `Deploy-NestedESXi-And-Installer.ps1`(OVA 一鍵部署,密碼走 sops)+ `Prepare-NestedESXi.ps1`(vSAN/LSOM advanced settings)| [layer1-nested/](./layer1-nested/README.md) |
| 2 VCF Bring-up | scaffold | template/generator/submitter ready,等 9.1 OpenAPI 對齊欄位;timeout workaround 已記錄 | [layer2-bringup/](./layer2-bringup/README.md) |
| 3 Post-bringup | 部分 | scripts 待補;M02 VCF Operations/Automation 部署故障排除紀錄已寫入 | [layer3-postbringup/](./layer3-postbringup/README.md) |
| 4 Day-2 ops | ✅ | nested ESXi 9.0 → 9.1 升級 + vSAN/LSOM workaround 已實作 | [layer4-day2/](./layer4-day2/README.md) |

## 故障排除 / 設計參考索引

| 主題 | 文件 | 重點 |
|---|---|---|
| **vSAN — 叢集分裂** | [layer4-day2/Troubleshoot-VsanPartition.md](./layer4-day2/Troubleshoot-VsanPartition.md) | unicast peer list 空導致 cluster partition;診斷流程 + 加 peer 修復 + 指令快查 |
| **vSAN — 效能拖垮 etcd** | [layer3-postbringup/vcf-operations-automation-deploy-troubleshooting.md](./layer3-postbringup/vcf-operations-automation-deploy-troubleshooting.md) | nested-on-nested vSAN + resync 把 VSP Supervisor etcd fsync 拖到 135ms~4s → Fleet LCM timeout |
| **K8s 登入 / 檢查指令** | [layer3-postbringup/k8s-access-and-checks.md](./layer3-postbringup/k8s-access-and-checks.md) | VSP Supervisor / VCF Automation K8s 怎麼登入、etcd 健康度 / pod 狀態檢查指令速查 |
| **domainmanager timeout 調整** | [layer2-bringup/timeout-tuning.md](./layer2-bringup/timeout-tuning.md) | 慢速 lab 的 Installer / SDDC Manager timeout 參數(含 ×10 最終值、備份、回退) |
| **9.1 VCFMS IP 配置(設計參考)** | [layer2-bringup/vcfms-ip-allocation.md](./layer2-bringup/vcfms-ip-allocation.md) | 9.1 起 VCFMS 三種 IP 配置模式(IP Range / CIDR / explicit list)+ `excludeAddresses`;VCF Installer JSON 與 SDDC Manager `/vcf-management-components` API 兩種入口 |
| **安全關機 VCF Services Runtime** | [layer4-day2/Safe-Shutdown-VCF-Services-Runtime.md](./layer4-day2/Safe-Shutdown-VCF-Services-Runtime.md) | 計畫性停機(維運/斷電/冷備份/退役)時的官方腳本流程(KB 440874),三種模式 dry-run / skip-poweroff / 完整關機 |
| **整 lab 關機 / 開機 SOP** | [layer4-day2/Shutdown-Lab.md](./layer4-day2/Shutdown-Lab.md) | 10 phase 順序:tenant → VCFMS → VCF Ops/Fleet → NSX → SDDC Mgr → Installer → M02 vCenter → nested ESXi →(選)外層 →(務必最後)DNS/跳板;含開機反序、緊急中止 |

## Quick start

```bash
# 0. Bootstrap automation host (10.0.0.65)
LAB_USER=labops bash scripts/bootstrap-automation-host.sh
su - labops
source /opt/vcf-lab/.venv/bin/activate          # Python venv

# 1. Layer 1: nested ESXi 部署前準備 (開機後、VCF Installer 前)
pwsh ./layer1-nested/Prepare-NestedESXi.ps1

# 2. Layer 2: VCF bring-up (腳本自己 sops 解密 secrets，不需先 source)
pwsh ./layer2-bringup/New-VcfLab.ps1 -VcfInstaller https://10.0.1.5

# 4. Layer 4: day-2 (例: 批次升級 nested ESXi 到 9.1)
pwsh ./layer4-day2/Run-BatchUpgrade.ps1
```

## Inventory & Secrets

所有腳本從 `inventory/lab.yaml` 取拓樸資訊(IP、hostname、VM name、datastore)。
密碼放 `inventory/secrets/lab.yaml`,**sops + age 加密過才 commit**,不會明文進 git;欄位範本見 `inventory/secrets/lab.example.yaml`。

```bash
# 初次建立密碼檔
cp inventory/secrets/lab.example.yaml inventory/secrets/lab.yaml
# 填值後加密
sops -e -i inventory/secrets/lab.yaml

# 之後編輯 (自動解密 -> 編輯 -> 加密)
sops inventory/secrets/lab.yaml

# 在 shell / bash 腳本裡讀
source scripts/load-secrets.sh
echo "$ESXI_ROOT_PW"
```

> Layer 2 的 PowerShell 腳本會自己呼叫 sops 解密,**不需要** 先 `source load-secrets.sh`。

## 前置需求

- **PowerShell 7 (`pwsh`)** — 不要用 5.1(中文字串編碼會壞)
- **PowerCLI 13.x** — 第一次跑腳本會自動裝
- automation host 上需有 `sops` / `age` / age 私鑰(`~/.config/sops/age/keys.txt`)才能解密 secrets
