# nested-workarounds — nested VCF 9.1 lab 才需要的「眉角」

這些是**選用、獨立**的腳本。一般(實體 / 高效能儲存)的 VCF lab **不一定需要**;
nested-on-nested(nested ESXi + nested vSAN)環境才會踩到這些雷。每支只做一件事、
都可帶參數給別的 lab 用。預設值對齊本環境(home.lab / 10.0.0.101 / 10.0.1.x / VMware1!)。

| 腳本 | 解決的問題 | 何時跑 |
|---|---|---|
| `Reset-TrunkPromiscuous.ps1` | 外層 ESXi 7.x dvSwitch swsec stale → nested ESXi 部完 ping 不到 | 每次部/重部 nested ESXi 後若連不到 |
| `Connect-OfflineDepot.ps1` | installer 接 offline depot;**用 IP 不用 FQDN**、HTTP no-auth 避免自簽憑證 | bring-up 前(installer 起來後)|
| `Disable-NetworkRollback.ps1` | vmk 遷 vDS 時 nested L2 收斂慢被 vCenter rollback | inner vCenter 起來後、host 遷 vDS 前(每次重部會重置)|
| `Disable-HaAdmissionControl.ps1` | HA admission control 擋住 VSP appliance 部署 | 卡在 VSP 且看不到 VSP VM 時 |
| `Set-VsanFtt0.ps1` | FTT=1 雙寫拖垮 etcd fsync;`-ReapplyExisting` 連現有 VM 一起改 | VSP 階段(etcd 慢)|
| `Set-NestedReservations.ps1` | 外層超賣 swap nested ESXi → etcd I/O 災難級慢 | VSP 階段 / 部署前預防 |
| `Set-DomainManagerTimeouts.ps1` | plink+pty/su 調大 domainmanager VSP/LCM timeout + restart(解 "failed after 60 retries")| LCM/VSP timeout 失敗時,套到 SDDC Manager(+installer)|
| `Watch-Bringup.ps1` | 監控 bring-up 進度到完成/失敗 | bring-up 期間任何時候 |

> **LCM/VSP 卡關完整除錯 → [VSP-LCM-troubleshooting.md](VSP-LCM-troubleshooting.md)**(含「281 後絕不刪 VSP」「縮 pool 解 retry 死結」「plink 取 root」)。

## VSP(Supervisor)卡住的典型處理順序
nested vSAN 上 VSP 的 etcd 很容易因儲存太慢起不來(`crictl logs etcd` 會看到 "took too long" / 每操作數秒)。依序:
1. `Disable-HaAdmissionControl.ps1`(讓 VSP appliance 放得下去)
2. `Set-VsanFtt0.ps1 -ReapplyExisting`(寫延遲減半,含現有 etcd VM)
3. `Set-NestedReservations.ps1`(防 swap)
4. 還不行 → 降低外層 vSAN I/O 競爭(關非必要重 I/O VM)或換更快儲存

## 一般 lab 通常只需要
`Connect-OfflineDepot.ps1`(若用 offline depot)。其餘是 nested/小容量環境專屬。

> 完整背景見 repo 記憶:`vcf91-nested-networking` / `vcf91-bringup-progress`。
