# Layer 1 — Nested ESXi 部署

從零開始把 4 台 nested ESXi VM 開到外層 vCenter (labvc.lab.com) 上，並在 VCF Installer 啟動前完成預備設定。

## 腳本

| 檔案 | 用途 | 時機 |
|---|---|---|
| `Set-DnsRecords.ps1` | 從 inventory 自動建/驗證所有 A + PTR 記錄(idempotent),整合自 vcf9-lab-automation 的 add-dns + check-dns | **最先**(部署前,跑在 DNS server 10.0.0.200) |
| `Deploy-NestedESXi-And-Installer.ps1` | 從 OVA 部署 4 台 nested ESXi(10.0.1.14–17)+ VCF Installer(10.0.1.4)到外層 vCenter,並產出 bring-up JSON 範本 | 零起點 |
| `Prepare-NestedESXi.ps1` | 套用 6 個 vSAN/LSOM nested lab advanced settings | ESXi 開機後、VCF Installer 前 |

> **環境**: domain `home.lab`、mgmt `10.0.0.0/23`(對齊實機 DNS 10.0.0.200,非舊版 lab.com)。

### Set-DnsRecords 跑法
```powershell
pwsh ./Set-DnsRecords.ps1            # 建/補齊 (idempotent: 已對的 skip, 漂移的 update, 缺的 add)
pwsh ./Set-DnsRecords.ps1 -Verify    # 只驗證 forward A / reverse PTR / 重複 IP
pwsh ./Set-DnsRecords.ps1 -WhatIf    # 試跑, 不改 DNS
```

## 跑法

```powershell
# 1. 部署 nested ESXi + VCF Installer(需 inventory/secrets/lab.yaml 用 sops 加密好)
pwsh ./Deploy-NestedESXi-And-Installer.ps1

# 2. ESXi 開機進 OS 後,套用 lab advanced settings
pwsh ./Prepare-NestedESXi.ps1

# Prepare 的其他用法
pwsh ./Prepare-NestedESXi.ps1 -DryRun                       # 只看不改
pwsh ./Prepare-NestedESXi.ps1 -Hosts 10.0.1.14,10.0.1.15    # 指定 host
```

## Deploy-NestedESXi-And-Installer 說明

- 改寫自 [kostenyang/vcf9-lab-automation `autodeployvcf91m02.ps1`](https://github.com/kostenyang/vcf9-lab-automation/blob/main/autodeployvcf91m02.ps1)(架構源自 William Lam vcf-fleet-automated-lab-deployment)。
- **與原版差異**:所有密碼改為從 `inventory/secrets/lab.yaml`(sops 加密)讀取,預設值是 placeholder;sops/age 沒裝或 secrets 沒填好會在 pre-check 停下。
- 用到的 secret 欄位:`esxi.root_pw`、`outer_vcenter.sso_admin_pw`、`inner_vcenter.{root_pw,sso_admin_pw}`、`sddc_manager.{root_pw,admin_pw}`、`vcf_installer.{root_pw,admin_pw}`、`nsx.{root_pw,admin_pw,audit_pw}`、`vcf_ops.{root_pw,admin_pw}`、`vcf_fleet.{root_pw,admin_pw}`、`vcf_collector.root_pw`(欄位範本見 [inventory/secrets/lab.example.yaml](../inventory/secrets/lab.example.yaml))。
- 部署完會在當前目錄產出 `vcf9-m02-config.json`(VCF Installer bring-up 用),須手動補各 ESXi 的 `sslThumbprint`,再交給 [layer2-bringup/](../layer2-bringup/README.md)。
- OVA 路徑寫死在腳本頂部(`E:\9.1\Nested_ESXi9.1.0.0_*.ova` 等),依環境調整。

## 套用的 Advanced Settings

| Setting | 值 | 說明 |
|---|---|---|
| `/LSOM/VSANDeviceMonitoring` | 0 | 關閉裝置監控，避免 nested 環境誤判磁碟錯誤 |
| `/LSOM/lsomSlowDeviceUnmount` | 0 | 關閉慢速磁碟偵測 |
| `/VSAN/SwapThickProvisionDisabled` | 1 | 停用 swap thick provision |
| `/VSAN/Vsan2ZdomCompZstd` | 0 | CPU 受限環境回退 LZ4（不用 Zstd） |
| `/VSAN/FakeSCSIReservations` | 1 | nested vSAN 在 physical vSAN 上正常運作（必要） |
| `/VSAN/GuestUnmap` | 1 | TRIM/UNMAP 傳遞到底層 physical vSAN |

## TODO

- [ ] 把 IP / hostname / OVA 路徑也拉進 `inventory/lab.yaml`(目前還寫死在腳本頂部)
- [ ] Kickstart cfg(自動填 root pw / network / hostname)取代 OVA properties 路徑
