# VCF 9.1.1 mgmt domain → vSAN Stretched Cluster（3+3 + witness，走 SDDC Manager API）

日期：2026-09-18。前提：mgmt domain `m01` bring-up 已完成（見 `VCF911-MGMT-BRINGUP-2026-09-15.md`）。
VCF 的 stretch **只有 API**（SDDC Manager UI 無此功能）。

## 設計決策
- **VCF 要求兩個 AZ 主機數相等**（[Broadcom 文件](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-private-cloud-infrastructure/stretching-clusters.html)）。
  AZ1 原 4 台，外層 512GB 裝不下 8×96GB → 採 **3+3**：先從 mgmt cluster 移除 esx04，AZ2 加 3 台。
- 記憶體配置：AZ1 3×96GB（reserved）+ AZ2 3×**48GB**（reserved）+ witness 16GB = 448GB / 512GB。
- 單一 L2 trunk（VCF91-Nested-Trunk）→ AZ2 沿用同一個 network pool `m01-np01`（vMotion VLAN130 / vSAN VLAN140）、同一 TEP VLAN 150。
- witness：用 nested ESXi template 起一台小的（4vCPU/16GB，disk 10/25），**不用 witness appliance**；加進 vCenter 當 standalone host（cluster 外）。

## 步驟
### A. 移除 esx04（cluster compaction）
```
POST  /v1/clusters/{clusterId}/validations   {"clusterCompactionSpec":{"hosts":[{"id":"<esx04-id>"}]}}
PATCH /v1/clusters/{clusterId}               同 body → task「Removing host(s) from cluster」
DELETE /v1/hosts                              [{"fqdn":"esx04.alan.lab"}]   → decommission
```
⚠️ **踩雷：卡在「Enter Maintenance Mode on ESXi Hosts」**——domainmanager log `Test connection to esx04:22 failed`。
bring-up 硬化把 nested ESXi 的 **SSH 關了**，VCF 主機操作需要 SSH。用 vCenter API 開 `TSM-SSH`（StartService + policy on）後 3 分鐘內跑完 45/45。
→ **新加的主機先把 SSH 開著並設 policy=on**。

### B. DNS + 部署 AZ2 三台 + witness
- dnsmasq（110.85）`/etc/dnsmasq.d/alan-lab.conf` 加 `host-record=esxNN.alan.lab,esxNN,192.168.120.6N`（esx05–07 = .65–.67，esx-witness = .68），restart dnsmasq。
- OVA 部署同 bring-up 的 nested ESXi（guestinfo），AZ2 24vCPU/48GB disk 40/250；witness 4vCPU/16GB disk 10/25。
- 套 6 個 vSAN nested advanced settings，SSH 開 + policy on。
- ⚠️ **踩雷：commission 驗證「Host must have only Management tag enabled on the VMkernel」**——William Lam template 的 vmk0 預設開了 vMotion+vSAN tag。
  用 PowerCLI `Set-VMHostNetworkAdapter -VMotionEnabled $false -VsanTrafficEnabled $false ...` + `esxcli network ip interface tag remove` 清到只剩 `Management`。

### C. Commission AZ2 主機
```
POST /v1/hosts/validations  [ {fqdn, username:root, password, storageType:"VSAN", networkPoolId, networkPoolName, sslThumbprint} ×3 ]
POST /v1/hosts              同 body → task「Commissioning host(s)」 → 狀態 UNASSIGNED_USEABLE
```

### D. Witness（pyvmomi）
1. `Datacenter.hostFolder.AddStandaloneHost_Task(ConnectSpec(hostName, root/pw, sslThumbprint, force=True))` → 加進 `vcf-m01-dc01`，cluster 外。
2. vSwitch0 加 portgroup `vsan-witness`（VLAN **140**）→ `AddVirtualNic` vmk1 = **192.168.140.68/24** → `SelectVnicForNicType('vsan','vmk1')`。
3. 驗證：`vmkping -I vmk1 192.168.140.5` 通、`esxcli vsan network list` 顯示 vmk1 traffic=vsan。

### E. Stretch
先取既有 VDS 對應（AZ2 必須相同）：`vcf-m01-cl01-vds01`，vmnic0→uplink1、vmnic1→uplink2。
```json
{"clusterStretchSpec":{
  "hostSpecs":[{"id":"<esx05-id>","hostname":"esx05.alan.lab",
    "hostNetworkSpec":{"vmNics":[{"id":"vmnic0","vdsName":"vcf-m01-cl01-vds01","uplink":"uplink1"},
                                 {"id":"vmnic1","vdsName":"vcf-m01-cl01-vds01","uplink":"uplink2"}]}}, ...×3],
  "witnessSpec":{"fqdn":"esx-witness.alan.lab","vsanIp":"192.168.140.68","vsanCidr":"192.168.140.0/24"},
  "witnessTrafficSharedWithVsanTraffic":true,
  "secondaryAzOverlayVlanId":150,
  "isEdgeClusterConfiguredForMultiAZ":false,
  "deployWithoutLicenseKeys":true}}
```
```
POST  /v1/clusters/{clusterId}/validations   → SUCCEEDED（一次過；同 TEP VLAN、無 license key 都接受）
PATCH /v1/clusters/{clusterId}               → task「Stretch vSAN Cluster - vcf-m01-cl01」（id 523a173a）
```

## 工具
- API helper：scratchpad `sddc_api.py`（token 用 administrator@vsphere.local 打 SDDC Manager 120.4）；跳板機（depot VM 110.85）`~/vcf/` 也有一份，`~/venv`（paramiko/pyvmomi/requests）。

### F. 第一次跑的結果與踩雷
- 步驟 80-82(Configure vSAN Stretch Cluster / Update vSAN Storage Profile / Health Service)**都過**:
  `esxcli vsan cluster get` 7 members(含 witness)、fault domain `vcf-m01-cl01_primary-az-faultdomain` / secondary、preferred = primary。
- 89/114 `Remediate ESXi Host(s) to be Compliant with Cluster's Image` **FAILED**:`VLCM_REMEDIATE_PERSONALITY_FAILED` / `Health Check for 'vcf-m01-cl01' failed`。
  SDDC Manager 只給這句;真正原因要看 vCenter `/var/log/vmware/vmware-updatemgr/vum-server/vmware-vum-server.log`:
  ```
  [vSAN] [com.vmware.vcIntegrity.lifecycle.health.vsan.cluster_maintenance] returned status: NOT_OK
  health status for perspective [BEFORE_ENTER_MAINTENANCE] is: NOT_OK for service(s) [vSAN]
  ```
  = 「主機無法進 vSAN maintenance mode」。原因:VCF 在 step 81 把 `vcf-m01-cl01 vSAN Storage Policy` 改成 **PFTT=1 + SFTT=1**(每物件 4 份),
  所有物件正在 resync(535GB 待同步、13 個 policy pending)→ 任何主機進 MM 都會讓物件 reduced availability。
  而且容量算不過:datastore 1500G 已用 1091G、還要再 resync 535G。
- **處置**:policy 改成 **PFTT=1 + SFTT=0**(跨站鏡像、站內單份;等同 VCF 內建 `Management Storage Policy - Stretched Lite`),
  再對每台 VM `ReconfigVM_Task(vmProfile + 每顆 disk profile)` reapply(policy 改完 SPBM 只標 `outOfDate`,不會自動套)。
  scratchpad `set_sftt0.py` + `reapply_policy.py`;resync 立刻降到 260GB。
  content library 的 `vcf-services-runtime-template-*` 不能 reconfigure(template),留 outOfDate。
- 等 resync 歸零(`esxcli vsan debug resync summary get`)後 `PATCH /v1/tasks/{taskId}` retry;**resync 沒完 retry 一定再失敗**(第 2 次就是這樣掛的)。
- vLCM 其他只有 WARNING:nested CPU 不支援(KB 82794)、`nested-esxi-customization` VIB 會被移除、AZ2 主機 build 25714478 vs image 25712839。
- 附帶:VCF 會把 ESXi 的 SSH 關掉(esx01-07 全關,witness 沒關);要看 esxcli 得先從 vCenter `StartService('TSM-SSH')`。
- **第 3 次(resync 歸零後)還是同一個 check 掛** → vum log 再往上看一行:`Overall vSAN cluster health is: red`。
  vLCM 的 `vsan.cluster_maintenance` 其實是拿 **vSAN Skyline Health 整體狀態** 當門檻,紅就擋。
  哪一項紅看 `/var/log/vmware/vsan-health/vmware-vsan-health-summary-result.log`:
  ```
  Group network health : red
     Test largeping health : red   (Host-12..64 ↔ Host-55, 8972, Red)
  ```
  = cluster 主機 vmk2(vSAN,MTU 9000)↔ witness(host-55)vmk1 的 **jumbo ping 不通**。
  witness 的 vSwitch0/vmk1 是手動建的,MTU 預設 1500。
  **修法(witness SSH)**:`esxcli network vswitch standard set -v vSwitch0 -m 9000; esxcli network ip interface set -i vmk1 -m 9000`,
  驗證 `vmkping -I vmk1 -s 8972 -d 192.168.140.5..10`(cluster vSAN IP 是 network pool 給的 140.5 起,不是 .6x)。
  → 步驟 D 建 witness 時就要把 MTU 設 9000。

### G. 完成(2026-09-19 01:46)
第 4 次 retry(MTU 修好後)`Stretch vSAN Cluster - vcf-m01-cl01` → **Successful 110/110**。
- `GET /v1/clusters/{id}` → `isStretched: true`,6 hosts ASSIGNED
- vCenter → Configure → vSAN → Fault Domains:Configuration type **Stretched cluster**、witness `esx-witness.alan.lab`、
  `vcf-m01-cl01_primary-az-faultdomain (preferred)` esx01-03 / `vcf-m01-cl01_secondary-az-faultdomain` esx05-07,兩邊各 52%
- `esxcli vsan cluster get` 7 members;81 objects 全 healthy、resync 0;vSAN health score 94
- 最終 policy:`vcf-m01-cl01 vSAN Storage Policy` = PFTT=1 / SFTT=0 / RAID-1(nested 容量考量,非 VCF 預設的 SFTT=1)

## 失敗紀錄總表
| 次 | 掛在 | 真因 | 處置 |
|---|---|---|---|
| 1 | 89/114 Remediate ESXi(vLCM HealthCheckFailed) | vSAN 全物件 resync 中(policy 改 PFTT1/SFTT1) | 改 SFTT=0 + reapply,等 resync |
| 2 | 同上(立刻 retry) | resync 沒完 | — |
| 3 | 同上(resync=0 後 retry) | vSAN Skyline Health red:largeping(witness vmk1 MTU 1500) | witness vSwitch0/vmk1 MTU 9000 |
| 4 | — | — | **Successful** |

## 截圖(shots/)
| 檔名 | 內容 |
|---|---|
| 01-sddcm-hosts-3plus3.png | SDDC Manager Hosts:esx01-03 Active、esx05-07 Error(第 1 次 remediate 失敗後) |
| 02-sddcm-tasks-stretch.png | Tasks 面板:Stretch task retry 中,Remediate ESXi 74% |
| 03-sddcm-hosts-all-active.png | 6 台全 Active |
| 04-sddcm-tasks-stretch-successful.png | Dashboard:Stretch vSAN Cluster Succeeded |
| 05-vcenter-vsan-fault-domains.png | **Stretched cluster / witness / primary+secondary FD 各 3 台** |
| 06-vcenter-vsan-health.png | vSAN Health score 97(02:06 重測,MTU 紅燈已消失,只剩 Disk Balance 黃)、24h trend 可見 stretch 期間掉到 ~45 再回來 |
| 07-vcenter-hosts-clusters-3plus3-witness.png | Hosts & Clusters 樹 |
| 08-vcenter-vsan-virtual-objects.png | Virtual Objects |

## 給下次的 checklist(stretch 前先做,可省 3 次失敗)
1. 新主機 SSH 開 + policy on;vmk0 只留 Management tag。
2. witness vmk(vSAN)**MTU 9000**(vSwitch + vmk 都要),`vmkping -s 8972 -d` 到每台 cluster vSAN IP。
3. stretch 前先算容量:VCF 會套 PFTT=1/SFTT=1(4 份)。裝不下就 stretch 完立刻把 policy 改 SFTT=0 並 reapply。
4. Remediate 掛 `HealthCheckFailed` → 看 vCenter vum-server.log 的 `[vSAN] ... returned status` 與 `Overall vSAN cluster health`,
   再看 `vmware-vsan-health-summary-result.log` 哪一項 red。resync 沒歸零、health 沒綠,retry 必敗。

---

# Round 2:整輪重做(2026-09-20,為了 step-by-step 截圖 + 驗證腳本)

流程:**unstretch → decommission AZ2 → 移除 witness → commission → witness_prep → stretch → SFTT=0 → 驗證**。
截圖在 `shots-redo/`(每個階段一組:SDDC Manager Tasks / Hosts / Unassigned + vCenter Fault Domains / Hosts / witness vmk / resync / health)。

## 時間軸
| 時間 | 事件 |
|---|---|
| 11:33–11:54 | `unstretch --watch`:57/57 Successful(20 分)。cluster 回 3 台,esx05-07 → `UNASSIGNED_UNUSEABLE` |
| 12:00 | `DELETE /v1/hosts` esx05-07 decommission(1 分);witness 從 vCenter Disconnect + Destroy |
| 12:05–13:20 | **AZ2 主機清到能 commission**(見下,花最久) |
| 13:23 | commission 三台:validate SUCCEEDED → 2 分完成 → `UNASSIGNED_USEABLE` |
| 13:30 | `witness_prep.py`:加 standalone host、vSwitch0 MTU 9000、vmk1 140.68/9000、vsan tag;jumbo ping 140.5-7 全通 |
| 13:35 | `gen-stretch-spec` → `stretch --validate-only` SUCCEEDED → `stretch --watch`(task `e783affa`) |
| 14:02 | **Failed 67/114**:`Migrate ESX Host Management vmknic(s) to vSphere Distributed Switch` esx07 — `VSPHERE_CONFIGURE_HOST_DVS_FAILED / An error occurred while communicating with the remote host` |
| 14:32 | retry #1 又掛 esx07 同一步(清外層 vNIC 學習表沒用) |
| 14:59 | retry #2:esx07 過了,**esx05** 掛同一步 → 確認根因是 vmk0 MAC(下) |
| 15:13 | retry #3(esx05/06 vmk0 換獨立 MAC):**Successful 110/110**。Remediate 一次過 |
| 15:15 | policy PFTT=1/SFTT=1 → SFTT=0 + reapply;resync 343GB |

## 新踩的雷(都跟「unstretch 後重新 commission」有關)

### 1. unstretch 把 AZ2 主機留在什麼狀態
- 踢出 vCenter,但 **maintenance mode 沒退**
- **vmk0 留在孤兒 DVS proxy 上**(`vcf-m01-cl01-vds01` 還在主機的 net-dvs 設定裡)、vSwitch0 已被刪
- SSH 服務關、**firewall ruleset `sshServer` 也關**(每次跑 commission validation 還會再關一次)
- vSAN 磁碟 partition 還在

而 `POST /v1/hosts/validations` 一條一條擋(每修一項才告訴你下一項):
`ESXi host is in maintenance mode` → `Host does not contain vSphere Standard Switch - vSwitch0` →
`vSwitch0 must have only one NIC as Uplink` → `vSAN Partition found on the host` →
`Distributed Switch(es) found on the Host` → `Host MUST have only one Standard Switch`。

### 2. 怎麼在主機斷網時修它:外層 vCenter 的 Guest Operations
William Lam 的 nested ESXi 有 VMware Tools → 從外層 vCenter(110.32)用 `guestOperationsManager` 把 shell script 丟進去跑,**不需要網路**:
`tools-guest_fix.py <外層 VM 名> <script.sh>`(repo 內,密碼用環境變數 OUTER_VC_PASS / NESTED_ROOT_PASS)(InitiateFileTransferToGuest + StartProgramInGuest + 抓 /tmp 輸出)。
限制:guest-ops 是沙箱,`esxcli` 可以,`net-dvs` / `esxcfg-vswitch -Q` / `vsish` / `/sbin/auto-backup.sh` 會 `Operation not permitted` → 這些要用 SSH。

### 3. 最終清法(每台)
```
# guest-ops(斷網也能跑)
esxcli network vswitch standard add -v vSwitch0
esxcli network vswitch standard portgroup add -p "Management Network" -v vSwitch0      # VLAN 0(lab 管理網是 untagged;誤設 120 會斷)
esxcli network vswitch standard uplink add -u vmnicX -v vSwitch0
esxcli network vswitch standard policy failover set -v vSwitch0 -a vmnicX              # ← uplink add 只會放到 Unused,一定要 set active
esxcli network ip interface remove -i vmk0 ; esxcli network ip interface add -i vmk0 -p "Management Network"   # 不帶 -M,拿新 MAC
esxcli network ip interface ipv4 set -i vmk0 -t static -I <ip> -N 255.255.255.0 ; esxcli network ip route ipv4 add -n default -g 192.168.120.1
# SSH(通了之後;先用 API 開 TSM-SSH + firewall sshServer)
esxcfg-vswitch -Q vmnic0 -V <dvport> vcf-m01-cl01-vds01 ; net-dvs -d vcf-m01-cl01-vds01
esxcli network vswitch standard remove -v DvsPortset-0      # 殭屍 portset,重開也不會消失,要手動 remove
esxcli vsan cluster leave ; esxcli vsan storage remove -d/-s <disk>
/etc/init.d/hostd restart                                   # hostd 還會快取 DVS
# 最後 vSwitch0 只留 vmnic0 一張 uplink(VCF 要求)
```
(用 API `UpdateNetworkConfig` 一次做會 `InvalidArgument`;分步用 API 做又會把 DVS kernel 狀態弄壞 → 上面這套最穩。)

### 4. vmk0 的 MAC 不能等於 vmnic0 的 MAC(外層 vDS MAC learning)
外層 trunk portgroup `VCF91-Nested-Trunk`:**MAC learning 開、forged transmits 允許、promiscuous 關**。
MAC learning 不會把「已指派給某個 port 的 vNIC MAC」學到別的 port。
我修復時把 vmk0 的 MAC 設成 vmnic0 的 MAC → VCF 把 vmk0 搬到 VDS 後 hash 到 uplink2(vmnic1)送出 → 外層丟包 →
`Migrate ESX Host Management vmknic(s) to vSphere Distributed Switch` 失敗「communicating with the remote host」,而且哪台掛看 hash 運氣(esx07 兩次、esx05 一次)。
**vmk0 要用獨立 MAC**(`esxcli network ip interface add` 不帶 `-M` 就會給 00:50:56:6x 的新 MAC;原廠 OVA 的 vmk0 也是合成 MAC)。
同理:vSwitch0 只有 vmnic1 而 vmk0 用 vmnic0 的 MAC 也不通。

### 5. 腳本修正
- `validation_wait`:**cluster 的 `/validations` 是同步**(POST 直接回 COMPLETED,GET `/validations/{id}` 回 400);hosts 的才是非同步。舊版會永遠等 → 已改成兩種都吃。
- 新增 `unstretch --cluster X [--validate-only] [--watch]`(`clusterUnstretchSpec`)。
- `stretch` 現在會把 task id 寫到 `stretch-task.txt`(retry 用)。

## 這輪比上輪好的地方
- witness 一開始就 MTU 9000 → **Remediate 一次過**,沒再撞 vSAN health red。
- policy 在「Update vSAN Storage Profile」剛過時就改 SFTT=0 → resync 343GB(上輪 535GB)。
