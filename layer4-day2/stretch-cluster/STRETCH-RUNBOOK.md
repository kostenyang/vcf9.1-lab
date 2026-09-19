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

## 截圖(shots/stretch/)
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
