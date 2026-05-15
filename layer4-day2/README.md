# Layer 4 — Day-2 ops

跑現有環境的補丁/升級/維運。不負責 bring-up。

## 內容

| 檔案 | 用途 |
|---|---|
| `Upgrade-NestedESXi91.ps1` | 單台 nested ESXi 升級主腳本（Depot / IsoBoot 兩模式） |
| `Run-BatchUpgrade.ps1` | Wrapper，對 4 台批次跑 depot 升級 |
| `Run-BatchIsoBoot.ps1` | Wrapper，透過外層 vCenter 給 4 台掛 ISO 重開 |
| `Exit-MaintenanceMode-All.ps1` | 4 台一鍵退出 maintenance |
| `Apply-NestedVsanWorkarounds.ps1` | 套用 6 個 vSAN/LSOM lab workaround advanced settings |
| `ESXi91-ISO-Upgrade-Steps.md` | ISO 開機升級 console 操作步驟 + lab workaround |
| `Troubleshoot-VsanPartition.md` | vSAN cluster partition 完整除錯流程（unicast peer list 空） |

## 跑法

```powershell
# 升 4 台 (PowerCLI depot 模式)
pwsh Run-BatchUpgrade.ps1

# 套用 vSAN/LSOM workaround（也可在 layer1 就跑）
pwsh Apply-NestedVsanWorkarounds.ps1

# DryRun 模式，只看目前值不更改
pwsh Apply-NestedVsanWorkarounds.ps1 -DryRun

# 看哪幾台已升上 9.1 + 順便退 maintenance
pwsh Exit-MaintenanceMode-All.ps1
```
