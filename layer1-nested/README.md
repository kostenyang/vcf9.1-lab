# Layer 1 — Nested ESXi 部署

從零開始把 4 台 nested ESXi VM 開到外層 vCenter (labvc.lab.com) 上，並在 VCF Installer 啟動前完成預備設定。

## 腳本

| 檔案 | 用途 | 時機 |
|---|---|---|
| `Prepare-NestedESXi.ps1` | 套用 6 個 vSAN/LSOM nested lab advanced settings | ESXi 開機後、VCF Installer 前 |

## 跑法

```powershell
# 套用 advanced settings（會提示輸入 ESXi root 密碼）
pwsh .\Prepare-NestedESXi.ps1

# DryRun：只看目前值，不修改
pwsh .\Prepare-NestedESXi.ps1 -DryRun

# 只跑指定 host
pwsh .\Prepare-NestedESXi.ps1 -Hosts 10.0.1.14,10.0.1.15
```

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

- [ ] 寫 `Deploy-NestedESXi.ps1`（部署 VM OVA 到外層 vCenter）
- [ ] Kickstart cfg（自動填 root pw / network / hostname）
- [ ] 整合 inventory/lab.yaml 讀取 host 清單
