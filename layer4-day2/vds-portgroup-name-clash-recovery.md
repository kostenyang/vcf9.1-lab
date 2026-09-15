# 🔴 VDS 與 portgroup 撞名 → 建叢集 workflow 壞掉，怎麼救

> 2026-09-14 在 m02 lab **真的跑壞一次再救回來**的完整實錄。
> 測試對象：NFS 兩節點叢集 `m01-cl03`（esx06 + esx07）。
> ⚠️ 這裡的 skip flag 只 nested/homelab 用，Broadcom 不支援。

---

## 0. 成因

vCenter 的 **datacenter network folder 是共用命名空間** —— DVS / dvPortgroup / 標準網路
不能同名。所以 spec 裡只要某個 portgroup 的名字剛好等於另一顆 VDS 的名字，就會撞。

最容易踩到的寫法（把 VDS 名字直接拿來當 portgroup 名）：

```json
"vdsSpecs": [
  { "name": "vDS_FuGuo-Test_MGMT",
    "portGroupSpecs": [
      { "name": "vDS_FuGuo-Test_MGMT-pg-mgmt", "transportType": "MANAGEMENT" },
      { "name": "vDS_FuGuo-Test_vSAN",        "transportType": "VMOTION" }   ← 撞名
    ] },
  { "name": "vDS_FuGuo-Test_vSAN", ... }                                     ← 同一個名字
]
```

先用 govc 確認到底是誰佔了名字（型別很重要）：

```bash
govc find -l /<datacenter>/network -name '<衝突的名字>'
# DistributedVirtualPortgroup  /m01-dc01/network/xxx   ← portgroup 佔名
# DistributedVirtualSwitch     /m01-dc01/network/xxx   ← VDS 佔名
```

---

## 1. 🔴 三個關鍵事實（都是實測，不是推論）

### 1-1 VCF validation 完全不擋

```
POST /v1/clusters/validations   →   SUCCEEDED      （零警告）
```

UI 上按下去之前**不會有任何提示**，只會在 workflow 跑到一半炸。

### 1-2 VCF 先建完所有 VDS，才建 port group

所以第二顆 VDS 會先被建出來、把名字佔走，接著建 portgroup 時才炸：

```
VSPHERE_CREATE_PORT_GROUPS_FAILED:
  Failed to create portgroup vDS_FuGuo-Test_vSAN in vDS dvs-3115
  on vCenter vcf-m02-vc01.home.lab | Error creating dvPortgroup
```

### 1-3 VCF 自己的 rollback 也被同一個撞名弄壞 ← 這才是「卡住」的根因

```
DELETE_PORTGROUPS_FROM_VCENTER_FAILED:
  Failed to delete portgroups vDS_FuGuo-Test_vSAN from vCenter ...
  | Expected 1 but did not find any MORs of a type
    DistributedVirtualPortgroup and name vDS_FuGuo-Test_vSAN
```

它要清掉那個 portgroup 時，**按名字找到的是 VDS（型別不符）** → 自動回滾失效，
殘留物只能人工處理。

---

## 2. 卡住後的實際狀態

| 位置 | 狀態 |
|---|---|
| SDDC Manager | cluster `ACTIVATING` → 之後 `ERROR` |
| vCenter | cluster 物件存在但**空的**（0 host、0 VM、無 vCLS）|
| vCenter | **兩顆 VDS 都留著**，各 0 hosts / 0 ports，只有自動產生的 DVUplinks portgroup |
| 任務 | `In Progress` 無限 retry，且 **`isCancellable = false`** |

> ⚠️ **Retry 沒用**：Retry 沿用同一份壞 spec；就算你先去 vCenter 把佔名物件改名讓路，
> 下一步 VCF 仍會去找/建那個同名 portgroup 再炸一次。**一定要清掉重送。**

---

## 3. 救援流程（每一步都實測過）

### Step 1 — 逼卡住的任務變 Failed

任務 `isCancellable=false`、retry 又只會重撞同一面牆，只能重啟服務：

```bash
systemctl restart domainmanager
```

- appliance root 不能直接 SSH → 走**外層 vCenter guest-ops**
  （`govc guest.upload` + `govc guest.run ... bash /tmp/x.sh`，別用多字 `bash -c`，會被拆）。
- 重啟後 **`/v1/tokens` 會先通、但 `/v1/clusters` 還 502**。
  要打真的走 domainmanager 的端點才算好：

```bash
until curl -sk -m 8 https://<sddcm>/v1/clusters -o /dev/null -w '%{http_code}\n' | grep -qE '^(401|200)'; do sleep 15; done
```

### Step 2 — 刪掉失敗的叢集（要先 mark）

```
DELETE /v1/clusters/{id}
→ 400 REMOVE_CLUSTER_NOT_INITIALIZED          ← 直接刪會被擋

PATCH  /v1/clusters/{id}   {"markForDeletion": true}     ← UI 上就是 "Mark for deletion"
DELETE /v1/clusters/{id}                                  → Remove Cluster 任務
```

### Step 3 — Remove Cluster 可能被 false-positive guardrail 擋

```
REMOVE_CLUSTER operation validation failed:
  Entity "m01-cl03", check "Cluster with powered-on VMs", severity CRITICAL
  "Cluster has 1 or more powered-on VMs."
```

但實際查證：vCenter 上該叢集 **0 host、0 VM、連 vCLS 都沒有**，兩台 ESXi 直連也是 `vms=0`。
VCF 讀的是自己 DB 裡殘缺的記錄。加到 `/etc/vmware/vcf/domainmanager/application.properties`：

```properties
vcf.skip.dayn.guardrails=true
vcf.skip.nsx.dayn.guardrails=true
```

`systemctl restart domainmanager` → `PATCH /v1/tasks/{id}` retry → **Successful**。

### Step 4 — 🔴 Remove Cluster 成功，但 VDS 不會被清掉

這是最關鍵的一點。Remove Cluster 報 Successful 之後：

```bash
govc find -l /m01-dc01/network -name 'vDS_FuGuo*'
# DistributedVirtualSwitch  /m01-dc01/network/vDS_FuGuo-Test_vSAN    ← 還在
# DistributedVirtualSwitch  /m01-dc01/network/vDS_FuGuo-Test_MGMT    ← 還在
```

確認沒有主機掛著再刪：

```bash
govc object.collect -s /m01-dc01/network/<vds> summary.numHosts   # 必須是 0
govc object.destroy /m01-dc01/network/<vds>
```

> **對照組（2026-09-14 收尾拆 lab 時實測）**：同一個叢集在**成功建立之後**再走正常的
> `markForDeletion` + `DELETE /v1/clusters/{id}`，**VDS 會被自動清乾淨**
> （`govc find -l /<dc>/network -name 'vDS_*'` 無殘留），而且不需要 guardrail skip flag。
> 👉 所以 **VDS 殘留只發生在「workflow 失敗、rollback 被撞名弄壞」的情況**，正常拆除不會留垃圾。

### Step 5 — 查 SDDC Manager DB 有沒有孤兒 vds row（KB 419626）

```bash
/usr/pgsql/16/bin/psql -h localhost -U postgres -d platform     # ⚠ 9.1 是 pgsql/16，KB 寫 15
  select id, name from vds;
  select vds_id from cluster_and_vds;
```

**本次實測結果：DB 是乾淨的** —— Remove Cluster 有正確清掉 DB，`vds` 只剩正常叢集那筆。
（只有「人工在 vCenter 刪 VDS、沒走 VCF 流程」才會留孤兒 row。真有孤兒才需要
先 snapshot SDDC Manager 再 `delete from vds where id='<id>';`）

### Step 6 — 主機會變 UNASSIGNED_UNUSEABLE

```
vcf-m02-esx06.home.lab   UNASSIGNED_UNUSEABLE
vcf-m02-esx07.home.lab   UNASSIGNED_UNUSEABLE
```

必須 **decommission → 重新 commission** 才會回到 `UNASSIGNED_USEABLE`：

```
DELETE /v1/hosts   [{"fqdn":"..."},{"fqdn":"..."}]
POST   /v1/hosts   [{...}]          # 重新 commission，會拿到新的 host id
```

### Step 7 — 改名後重送

只把撞名的 portgroup 改掉（VDS 名字可以完全不動）：

```
vDS_FuGuo-Test_vSAN   →   vDS_FuGuo-Test_MGMT-pg-vmotion
```

**結果：validation SUCCEEDED，workflow 一路 `m01-cl03 ACTIVE, hosts=2, NFS datastore`。**
同樣兩顆 VDS、同樣的名字，只改 portgroup 名就通了 —— 改名就是正解。

命名慣例建議：portgroup 一律 `<vds名>-pg-mgmt` / `-pg-vmotion` / `-pg-vsan` / `-pg-nfs`，
永遠不會跟 VDS 撞。

---

## 4. Bring-up（Installer）階段撞名怎麼辦

沒有 Retry 可救。主機要清乾淨（vSwitch0 以外的 VDS/portgroup、vSAN 分割區）
重跑 bring-up，spec JSON 改 portgroup 名。

---

## 5. 過程中順帶實測到的其他坑

- **建叢集的 `deployWithoutLicenseKeys` 要放 spec 最上層**（跟 `domainId` 同層）；
  放進 `clusterSpecs[]` 裡面無效，會一直報 `DEPLOY_WITHOUT_LICENSE_KEYS_MUST_BE_TRUE`。
  **加叢集（expansion）則是放在 `clusterExpansionSpec` 內** —— 兩個位置不一樣。
- **NSX IP pool 的 `pool_usage` 是快取值**：PATCH 加了 allocation_range 之後
  `total_ips` 還是顯示舊值，要靠重試任務驗證，不要被那個數字誤導。
  TEP 不夠會擋在 `Validate NSX Static IP Address Pool Specification`
  （`needed 4 IP addresses but found 1`）。
- **nested 環境 CPU 打滿會讓 NSX cluster API 回 503**
  （`/api/v1/node/version` 還通、但 `/api/v1/cluster/status` 503，VIP 也 ping 不到）
  → SDDC Manager 會報 `FAILED_TO_FETCH_NSX_VERSION`。關掉多餘的 nested host 即恢復。
- **重啟 domainmanager 會把進行中的任務打成 `The task was interrupted`**（可 retry）。
  改 `application.properties` 後一定要 restart 才會被進行中的 FSM 讀到。

---

## 6. 測試環境的建立與拆除（2026-09-14 完整紀錄）

為了做這個破壞測試臨時建的東西，以及事後如何完整還原。

### 建立
| 項目 | 內容 |
|---|---|
| esx06 / esx07 | 10.0.1.12 / 10.0.1.11，nested OVA → 升到 BOM 0200 → commission 到 `nfs-np01` |
| network pool | `nfs-np01`（VMOTION vlan13 `192.168.13.20-25` + NFS vlan15 `192.168.15.20-25`）|
| NFS datastore | `10.0.0.60:/nfs/vcftest`（在 vcd-nfs01 上**另開** export，沒動 VCD 的 `/nfs/vcd-transfer`）|
| 測試叢集 | `m01-cl03`（NFS 兩節點；vSAN 需 3 台、外部儲存只需 2 台）|
| TEP pool | `m01-cl01-tep01` 擴充 `192.168.19.61-80`（原本 50-60 只剩 1 個 IP）|

### 拆除順序（順序有講究）
```
1. esx05 decommission → govc vm.destroy → 刪 DNS A/PTR
2. m01-cl03: markForDeletion → DELETE          ← guardrail skip flag 必須「還留著」才不會被擋
3. esx06/esx07 decommission → vm.destroy → 刪 DNS
4. DELETE /v1/network-pools/{nfs-np01}
5. 移除 NFS export /nfs/vcftest（sed 掉 /etc/exports 那行 + exportfs -ra）
6. ★最後★ 才還原 skip flag + systemctl restart domainmanager operationsmanager
```
🔴 **第 2 步一定要排在第 6 步之前** —— 還原 flag 之後 Remove Cluster 會再次被
`Cluster has 1 or more powered-on VMs` 那個 false positive 擋住。

### 拆完的驗證
```
hosts    : esx01-04 ASSIGNED 9.1.0.0200.25557999      （回到原本 4 台）
clusters : m01-cl01 ACTIVE hosts=4
VDS      : 只剩 m01-cl01-vds01
exports  : 只剩 /nfs/vcd-transfer
flags    : domainmanager / operationsmanager 皆無殘留（備份 .bak-restore-*）
```
保留未還原（刻意）：NSX TEP pool `192.168.19.50-80`、`m01-np01` 的
vSAN `192.168.14.5-10` / vMotion `192.168.13.10-15` 擴充範圍。
