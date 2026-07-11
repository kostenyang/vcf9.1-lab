# CLAUDE.md — vcf9.1-lab（開場必讀）

> 這是 nested VCF 9.1 lab。這份是「動手前的硬性規則」,不是背景說明。違反 = 重來 12 小時。

## 🔴 VCF 重建 / bring-up / VSP 任何動作前(硬性)

1. **先讀這兩份**(唯一真相源,別憑印象):
   - `nested-workarounds/VSP-LCM-troubleshooting.md` — VSP/LCM 卡關全解法
   - `layer2-bringup/timeout-tuning-operations-log.md` — timeout 實作紀錄
2. **部完 vCenter/NSX/SDDC、進第 5 關 VSP 之前,必跑**:
   ```
   pwsh nested-workarounds/Apply-VspRecipe.ps1
   ```
   一鍵套齊上次成功配方:FTT=0 + 外層 Set-NestedReservations + timeout(**兩台:SDDC Manager 10.0.1.18 + Installer 10.0.1.4,含 `orchestrator.task.retry.max`**)。
3. **全打掉重建後這些 appliance 設定會歸零 → 每次重建都要重跑上面第 2 步。** 這次七輪血淚就是漏了它。

## 🔴 nested ESXi 重部後:Trunk-Nobinding 要 promiscuous ON(不是 MAC learning!)(2026-07-11 血淚)

- 部完 nested ESXi 常常 **host 開機健康、IP 對(DCUI 顯示 10.0.1.14 STATIC)但 ping 不到、installer 也連不到**。
- ✅ **proven 修法(唯一有效):Trunk-Nobinding 的 `AllowPromiscuous` 設 True(toggle False→True 重推 policy)**,4 卡全留 `Trunk-Nobinding`,4 台立刻 ping 通、443=200。mgmt vmk0 untagged 在 trunk 上**要靠 promiscuous 洪泛**才連得到 mgmt 網段(10.0.0.0/23 在 VLAN 2)。
- ❌ **MAC learning 對這個沒用**:2026-07-11 試過 MacLearning Enabled + promiscuous OFF → 4 台全連不到。promiscuous 與 MAC learning 互斥,**這裡一定要 promiscuous**。
- ❌ **不要把 mgmt 卡搬去 MGMT(VLAN2 access)**:雖然 mgmt 會通,但 spec 的 vMotion(tag3)/vSAN(tag4)/TEP(tag9)走 vmnic0+vmnic1,access port 會丟 tag → vSAN/NSX 壞。4 卡都必須 Trunk。
- ⚠️ 這 session PowerCLI 模組壞了(`Set-NetworkAdapter`/`Get-View`/`Get-VDSecurityPolicy` 報 `_connectionId` field not found)→ 改用純 **ExtensionData**:`$tpg.ExtensionData.ReconfigureDVPortgroup($cfg)`,`$cfg.DefaultPortConfig.MacManagementPolicy.AllowPromiscuous=BoolPolicy(True)`。搬網卡用 `$vm.ExtensionData.ReconfigVM` + `VirtualEthernetCardDistributedVirtualPortBackingInfo`(需 DVS `ExtensionData.Uuid` + pg `Config.Key`)。
- 能連的 VM(install9.1/vcf9depot/vcf9dltool)在 `MGMT`=VLAN 2;mgmt 網段 10.0.0.0/23 在 VLAN 2。

## 🔴 bring-up 前 NTP 硬性檢查(2026-07-11 血淚)

- spec 的 `ntpServers` **必須是「真的在服務 NTP」的 IP**。VCSA firstboot 的 `setnet` 階段硬性要求 NTP 同步成功,同步不到 → 「Deploy vCenter Appliance」直接 `COMPLETED_WITH_FAILURE`(內部連試 4 次全倒)。**驗證只把 Time Sync 當 WARNING,不擋,但部署把它當致命** → 別信驗證綠燈。
- 本 lab **唯一在服務的是 `10.0.0.200`(AD/DNS,stratum 1)**;`10.0.1.254`(舊 NTP,vSAN 重格前的,已不存在)、`10.0.0.1`(gw)、`10.0.0.101`(外層 vC)**都沒 NTP**。
- 送 bring-up 前先驗:從 installer(同網段)`ntpdate -q -t2 <ntp>`,要看到 `stratum`/`offset` 才算通。順手把 4 台 nested ESXi(10.0.1.14-17)NTP 也設 10.0.0.200 + 重啟 ntpd。
- 錯誤指紋:ci-installer log `com.vmware.applmgmt.err_ntp_sync_failed` / `Failed to sync to NTP servers`。log 在 installer `/var/log/vmware/vcf/domainmanager/ci-installer-*/workflow_*/vcsa-cli-installer-status-deprecated.json`。

## 🔴 VSP 分段 retry 鐵律

- VSP 是分段推進(268→270→281),每輪 retry 往前一段,`done` 要整個 VSP 完成才翻 5,別因為卡 4/8 就以為壞了。
- **retry 前**:刪光殘留 `bootstrap-vm-*` / `vcf-m02-vsp01-*`,確認 pool `10.0.0.226-240` 全空,再 `PATCH /v1/sddcs/{id}`(帶完整 spec)。
- **⚠️ VSP done≈281(cluster 完成)之後,絕對不能刪 VSP VM** → 會 `NoRouteToHost`、LCM 卡死、只能整個重跑。281 後 retry 一律保留 VSP。

## 存取備忘

- 內層 vCenter `10.0.1.19` / Installer `10.0.1.4` / SDDC Manager `10.0.1.18`;外層 vCenter `10.0.0.101`(pw `VMware1!`)。
- appliance root **不可直接 SSH**;最穩用 **vCenter guest-ops(VMware Tools,root/`VMware1!VMware1!`)**,繞過 sshd faillock。
- 明文密碼在 `inventory/secrets/lab.yaml`(**已 gitignore,repo 是 public,勿 commit / 勿推**)。
- 其餘拓樸/密碼看使用者 auto-memory `MEMORY.md`。
