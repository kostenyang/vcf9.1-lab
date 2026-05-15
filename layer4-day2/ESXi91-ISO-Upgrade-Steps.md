# Nested ESXi 9.0 -> 9.1 ISO Upgrade (手動 / 半自動)

兩條路：

- (A) **腳本路** — `Upgrade-NestedESXi91.ps1 -Mode IsoBoot ...` 用外層 vCenter
  把 ISO 掛到 nested VM、設 boot-once、開機，剩下你在 console 走 Upgrade。
- (B) **純手動路** — 自己在外層 vCenter / Workstation 上掛 ISO。

下面是 B 的步驟與升級時要注意的 lab workaround。

---

## 1. 升級前

1. 確認 nested VM 規格
   - vHW version >= 21（ESXi 9 需要）
   - vCPU >= 2, RAM >= 8 GB (lab 最低)
   - vNIC = vmxnet3
   - **Expose hardware assisted virtualization to the guest OS** = 勾
   - Firmware = EFI（建議；BIOS 也行但 Secure Boot 要關）
   - Secure Boot = **取消**（除非你有 vTPM；lab 一般關掉）
2. 在外層 vCenter 對 nested VM 拍個 snapshot（雖然你不要這動作，但這步真的建議做）
3. 把要升級的 host SSH 開起來 (Host -> Services -> SSH -> Start)
4. 在 host 上跑 `vim-cmd vmsvc/getallvms` 確認 nested host 自己上面沒有跑著任何 VM；
   若有，先關機或遷出。
5. （可選）`esxcli system maintenanceMode set --enable true`

## 2. 掛 ISO + 改 boot order

1. 在外層 vCenter，右鍵 nested VM -> Edit Settings
   - CD/DVD drive 1 -> Datastore ISO file -> 選 9.1 ISO
   - 勾 **Connect At Power On** 與 **Connected**
2. VM Options -> Boot Options
   - Force EFI setup = 一次性勾上，或
   - 直接 Boot Order 把 CD-ROM 拉到第一順位
3. Power on / Restart Guest

## 3. ISO 安裝畫面操作

1. 開機 boot 到 ESXi installer，讀到 `Welcome` 後按 Enter
2. F11 接受 EULA
3. 選 **要升級的本機 disk** -> 確認上面已有 9.0 安裝
4. 出現選單：
   - `Upgrade ESXi, preserve VMFS datastore`  <- **選這個**
   - (不要選 Install 否則 VMFS 會被清掉)
5. F11 開始升級
6. 升級完按 Enter reboot

## 4. Lab Workaround（升級時 / 升級後）

依 nested + VCF 9.1 lab 常踩到的：

| 狀況 | 解法 |
|------|------|
| `Unsupported CPU` 開機直接卡住 | 安裝器讀完 ISO 後在 boot menu 按 **Shift+O**，行尾加 `allowLegacyCPU=true` 再 Enter |
| 升級流程跳 `Hardware precheck failed` | 同上，或之後 `esxcli software profile update --no-hardware-warning` |
| TPM attestation warning | `esxcli system settings advanced set -o /UserVars/SuppressTpmAttestationWarning -i 1` |
| 進不到 maintenance mode (nested vSAN 卡住) | `esxcli vsan cluster leave` 後再升級，升完再重 join |
| 升完 host 起來 vSAN ESA 跳 HCL 錯 | （William Lam VCF 9.0.1 / 9.1 lab post 那批 advanced settings — 看那篇填進來） |
| VCF Installer / SDDC Manager 端 lab 旁路 | 看 William Lam 2026/05 那篇 VCF Installer & SDDC Manager workaround |

> ⚠ William Lam 該篇 (`/2026/05/vcf-9-1-comprehensive-vcf-installer-sddc-manager-configuration-workarounds-for-lab-deployments.html`) 我這邊沒辦法直接抓，
> 如果你要把那篇裡的具體 advanced setting / json patch 加進腳本，
> 把該段貼給我，我幫你補到 `Invoke-LabWorkarounds` 的 `TODO` 區塊。

## 5. 升級後驗證

```
ssh root@<host>
vmware -vl                         # 要看到 VMware ESXi 9.1.0 build-xxxxx
esxcli system version get
esxcli software profile get        # 確認 profile name 是 ESXi-9.1.0-...
uptime
```

接著 `esxcli system maintenanceMode set --enable false` 退出 maintenance。

如果是接 vCenter 的：去 vCenter 把 host disconnect -> connect 重抓一次，或在 vSphere
client 看 Host -> Summary 的 ESXi version 已經是 9.1.0。
