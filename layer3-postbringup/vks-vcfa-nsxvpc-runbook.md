# VKS 接進 VCFA:NSX VPC Supervisor 完整條件與踩坑(2026-08-25)

> **一句話**:VCFA 的 Namespace **只能**建在 `network_provider = NSX_VPC` 的 Supervisor 上。
> VDS + Foundation Load Balancer(`VSPHERE_NETWORK`)的 Supervisor **永遠接不進 VCFA**,
> 不管 Region / 租戶 / Quota / 網路怎麼設都沒用。

---

## 1. 硬相依鏈(逐項實測)

```
VCFA 開 VKS cluster
  └─ Namespace                    ← VPC 為必填(UI 顯示 "No compatible VPC found")
      └─ VPC                      ← 由 Regional Networking 自動建立
          └─ Regional Networking  ← 建立時硬性要 Edge Cluster 或 VNA Cluster
              └─ Centralized Connection   ← 精靈只收 NSX Tier-0 / VRF,不收 distributed VLAN
                  └─ NSX Edge 節點
  + Supervisor 本身必須以 NSX_VPC 啟用
```

錯誤指紋(用 VDS+FLB 的 Supervisor 建 Namespace 時):

```
vcenter.wcp.workload.create.network.provider.mismatch
Network provider "NSX_VPC" (provided in Workload Create specification)
does not match the Supervisor network provider "VSPHERE_NETWORK".
```

## 2. 官方文件要求(Broadcom TechDocs)

- The Supervisor control plane is associated with an NSX Project and VPC. The Gateway should be
  configured for **Centralized Connectivity** and in **Active-Standby mode** to support the stateful
  VPC services (NAT) required for VCF Automation's use of NSX Networking.
- The Workload Network will automatically use the **default NSX Project** and VPC Connectivity Profile.
- 部署 edge cluster 時:**若規劃跑 VKS,HA Mode 要選 Active/Standby**。

### 三個必要條件

| 條件 | 檢查方式 |
|---|---|
| Tier-0 = `ACTIVE_STANDBY` | `GET /policy/api/v1/infra/tier-0s/{id}` → `.ha_mode` |
| default 專案 TGW 接 **centralized** gateway connection | `GET /policy/api/v1/orgs/default/projects/default/transit-gateways/default/attachments` → `connection_path` 要是 `/infra/gateway-connections/...`,不是 `/infra/distributed-vlan-connections/...` |
| connectivity profile 同時有 external + private TGW blocks | `GET .../vpc-connectivity-profiles/default` → `external_ip_blocks` 與 `private_tgw_ip_blocks` 都不可為 null |

**成功指標**:Supervisor 啟用後 NSX 的 default 專案會出現 `kube-system_xxxxx` VPC。
若一直是 0 個 VPC,代表上面條件沒滿足。

## 3. Tier-0 改 ACTIVE_STANDBY(edge cluster 不用重部)

SDDC Manager **沒有刪除 edge cluster 的 API**(`Allow: PATCH,GET,HEAD,OPTIONS`,PATCH 只支援
EXPANSION / SHRINKAGE),但其實**只有 T0 需要重建**,edge cluster 與節點可完全沿用。

NSX 會擋就地變更:

```
Unable to switch the HA Mode ... as a gateway connection is created using the Tier0 and is attached to TGW
HA mode cannot be modified when interface(s) [...] exist
```

### 步驟

1. 先清掉所有對 T0 的引用:VCFA 的 Regional Networking → Provider Gateway(Centralized Connection)
   → NSX `gateway-connections` 應歸零
2. 備份 T0/T1 全部設定(`tier-0s/{id}`、`locale-services/default`、`interfaces`、`bgp`、
   `bgp/neighbors`、`tier-1s/{id}`)
3. 刪除順序:**T1 的 locale-services → T1 → T0 interfaces → T0 bgp neighbors → T0 locale-service → T0**
4. 用**相同的 id** 重建 T0(`PUT /policy/api/v1/infra/tier-0s/{原 id}`)→ SDDC Manager inventory 引用不會斷
5. 沿用**相同的 uplink IP** 重建 interfaces → 對端路由器的 BGP peer 設定一行都不用改
6. 重建 BGP、neighbors、T1

### 從備份還原時必須拿掉的兩個欄位(A/A 專用)

```
.stateful_services   →  Stateful services configuration is not allowed when Tier0 is Active-Standby
bgp .inter_sr_ibgp   →  BGP inter SR routing only applicable for Tier0 in active-active HA-mode
```

另外 A/S 要設 `ecmp: false`。

### connectivity profile 的 PATCH 是「取代」不是「合併」

改 `external_ip_blocks` 會把 `private_tgw_ip_blocks` 洗成 null,導致啟用 Supervisor 時報
`Private TGW IP Blocks must be set in VPC Connectivity Profile`。**PATCH 時兩個欄位要一起送。**

### default NSX 專案不可修改

```
System defined resource /orgs/default/projects/default cannot be updated/deleted.
```

專案物件本身的 `site_infos` / `external_ipv4_blocks` 改不了(WCP 查詢時這些欄位顯示為空,屬正常);
但**它的 TGW attachment 與 connectivity profile 可以改**,實際生效看的是後兩者。
自建 NSX 專案雖然做得到,但 gateway connection 跨 scope 引用會被擋
(`paths cannot be accessed ... neither belong to its scope nor are shared with it`)
→ **別手工復刻 VCFA 的多租戶管線**。

## 4. air-gap:WCP 會自己建訂閱式 content library(必踩)

沒有外網時 WCP 嘗試建訂閱庫抓映像 → `vcsp_library_not_found / The remote library is not reachable`,
而 Supervisor 只給 `FailedWithSystemError`、`config_status_messages` 全 null。
**真因只能從 vCenter tasks 挖**(`govc tasks -n 60 -json`,注意 JSON key 是小寫 `tasks`)。

要手動餵**兩個**本地 content library:

| 用途 | API | 生命週期 |
|---|---|---|
| Supervisor CP VM 映像 + spherelet | `PUT /api/vcenter/namespace-management/lifecycle/content/libraries` body `{"library":"<id>"}` | **vCenter 層,刪 Supervisor 後仍保留** |
| VKS / TKr 節點映像 | `PATCH /api/vcenter/namespace-management/supervisors/{id}/workloads/images/settings` | **per-supervisor,重建 Supervisor 就要重設** |

第二個的兩個坑:

- 回寫時**只送 `content_libraries`**;整包送會被空字串的 `registry.hostname` 擋
  (`Default Image registry hostname is not a valid IP or hostname`)
- k8s API 未起來時回 `Kube API server IP is unset` → 要輪詢重試直到 204

OVF item 名稱**必須**是 `supervisor-<版本>`(例:`supervisor-9.1.0.0200-25573614`)。

## 5. spherelet 裝不上時:手動裝(繞過 vLCM,且不需要 SSH)

vLCM 走 `ClusterApplySolutionTask`,只要叢集健康檢查(EHP)不過就整個中止:

```
TaskError.HealthCheckFailed  →  Health Check for <host> failed
```

本 lab 的觸發原因是 **vSAN health = yellow**(nested 環境的 `NVMe device is VMware certified` 假警報)。
結果:host 沒有 spherelet → 不會成為 k8s worker node → `cci-ns-controller-manager` 永遠 Pending
(`untolerated taint node-role.kubernetes.io/control-plane`)。

### VIB 就在 vCenter 裡(不必跨氣隙)

```
/storage/updatemgr/patch-store/hostupdate/vmw/vib20/spherelet/VMware_bootbank_spherelet_<ver>.vib
/usr/lib/vmware-wcp/spherelet/k8s-1.3{0,1,2}/spherelet-embedded.vib
/usr/lib/vmware-wcp/spherelet/vsphere-wcp-depot-embedded.zip
```

版本要對應 Supervisor 的 k8s 版本(k8s 1.32 → `9.0.1.32.x`),也可從
`GET /api/esx/settings/clusters/{cluster}/software/solutions` 的 `com.vmware.vsphere-wcp` 版本確認。

### 免 SSH 的安裝法(推薦)

`govc host.esxcli` 走 vSphere API,ESXi 的 SSH 可以維持關閉:

```bash
# 1) 從 vCenter 取出 VIB(vCenter root 走 guest-ops)
govc guest.download -vm '<vcenter-vm-path>' -l 'root:<pw>' \
  /storage/updatemgr/patch-store/hostupdate/vmw/vib20/spherelet/VMware_bootbank_spherelet_<ver>.vib \
  spherelet.vib

# 2) 放到叢集共用 datastore
govc datastore.mkdir -ds <datastore> -p spherelet
govc datastore.upload -ds <datastore> spherelet.vib spherelet/spherelet.vib

# 3) 每台 host 強制安裝
#    注意:govc 的 esxcli flag 一律要帶值,是 -f true 而不是 -f
govc host.esxcli -host '/<dc>/host/<cluster>/<host-fqdn>' -- \
  software vib install -v /vmfs/volumes/<datastore>/spherelet/spherelet.vib \
  -f true -maintenance-mode true

# 4) 驗證
govc host.esxcli -host '<host-path>' -- software vib list | grep -i spherelet
```

實測回應 `Operation finished successfully` / `RebootRequired: false`,4 台皆成功,**不需要進維護模式**。

## 6. 其他工具坑

- `govc host.service start -host <短名>` 會報 `default host resolves to multiple instances`
  → 要給**完整 inventory 路徑** `/<dc>/host/<cluster>/<fqdn>`
- Git-Bash 下即使設了 `MSYS_NO_PATHCONV=1`:
  - `curl -d @/tmp/x.json` 讀不到檔(Windows curl 收到字面 `/tmp/`)→ **改用相對路徑**
  - 值只要經過命令列參數(如 `jq --arg`)仍會被改寫成 `C:/Program Files/Git/...`
    → NSX 的 `/orgs/default/projects/default` 這種路徑**必須直接寫進檔案**再送
- NSX policy API 刪 T0 interface 很慢,單次 150s 也可能逾時 → 改「送出後輪詢清單」的方式
- Windows `ping` 收到上游 unreachable 也會回傳成功 → **判斷網段是否空閒要看路由表,不要用 ping**
- `consumption-domains/zones` 回的是 `{"items":[...]}`,不是裸陣列

## 7. VCFA 消費面備忘

- **provider 可直接進租戶入口** `/tenant/<org>/automation`,**不需要建租戶帳號**
- org 建立時自帶 `default-project`,Project 不用另外建
- 租戶側查詢要帶 header `X-VMWARE-VCLOUD-TENANT-CONTEXT: <orgUrn>`
- Region / Supervisor / Zone / VDC 走 `/cloudapi/v1/...`(不是 `1.0.0`);Org 走 `/cloudapi/1.0.0/orgs`
- 真 API spec:`GET /tm/api-explorer/provider/cloudapi.json`(swagger 2.0)
- API token 是**兩步**:
  1. `POST /oauth/provider/register` `{"client_name":"..."}` → 只回 `client_id`
  2. `POST /oauth/provider/token`(form)`grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`
     + `assertion=<access token>` + `client_id=<上一步>` → 回 `refresh_token`(這才是 API token)

  步驟 1 **會真的建立 token**,別拿它當存在性探測。

## 8. 相關文件

- `vks-airgap-runbook.md` — air-gap 取得 Supervisor / VKr 映像
- `vks-airgap-tkr-upload.md` — TKr / VKr 上傳細節
- `vcfa-supervisor-enablement-checklist.md`

---

## 9. 開 VKS guest cluster 才會踩到的四個坑(2026-08-26 補)

### 9.1 `default_kubernetes_service_content_library` 與懸空引用

`GET /api/vcenter/namespace-management/clusters/{cluster}` 有個
`default_kubernetes_service_content_library` 欄位,與 `workloads/images/settings` **是兩回事**。

🔴 **最坑的是**:`workloads/images/settings` 裡只要有**任何一個 content library 已被刪除**,
WCP 驗證整批失敗,導致映像同步完全停擺 —— 症狀是
`OSImage` 與 `KubernetesRelease` 永遠 0 個,但**沒有任何錯誤訊息**。

錯誤只有在 PATCH cluster 設定時才會冒出來:
```
Failed to validate Content Library UUID <id>, error: not found
```
清掉懸空引用(只保留仍存在的庫)後,controller 立刻動作:
```
kr.OSImage added {"name":"vmi-xxxx"}
kr.KR      added {"name":"v1.32.7---vmware.3-fips-vkr.1"}
```

**教訓**:刪 VCFA content library / Region 之前,先把它從 `workloads/images/settings` 移除。

### 9.2 Namespace 要自己掛 content library

建 VCFA Namespace 時若沒帶 `contentLibraries`,namespace 內不會有 `VirtualMachineImage`
(cluster-scoped 的 `ClusterVirtualMachineImage` 不會自動投影進去)。

```bash
# ⚠ v2 端點不支援 PATCH(回 404),要用 v1
curl -X PATCH https://<vc>/api/vcenter/namespaces/instances/<ns> \
  -d '{"vm_service_spec":{"content_libraries":["<libId>"],"vm_classes":["best-effort-small",...]}}'
```

### 9.3 storage class 名稱是「儲存原則」轉換來的,不是 datastore 名

namespace 綁 `vSAN Default Storage Policy` → k8s storage class 叫 **`vsan-default-storage-policy`**。
用 datastore 名(如 `m01-cl01-vsan-storage-policy`)會被 webhook 擋:
```
admission webhook denied: storage class(es): xxx not found
```

### 9.4 🔴 VPC External IP Block 必須能被 BGP 宣告出去 —— T0 要加 `TGW_STATIC`

guest cluster 的 API VIP 由 VPC 的 external IP block 配發(例:`192.168.20.1`)。
T0 **學得到**這條路由:
```
192.168.20.1/32 via 169.254.64.9 type=tgws
```
但 VCF 建出來的 T0 預設重分配規則**不含 TGW 類型**,所以不會宣告進 BGP
→ 整個 lab 網路對這個 VIP 是黑洞 → CAPI 無法檢查 guest cluster
→ Machine 條件全是 `InspectionFailed`,cluster 卡在 `Provisioned / Available=False`。

**修法**:PATCH T0 locale-service,在 `route_redistribution_types` 加入 **`TGW_STATIC`**
(保留原有全部類型與第二條 `SYSTEM-VCD-EDGE-SERVICES-REDISTRIBUTION` 規則)。

合法值可用「故意送錯值」的方式讓 NSX 吐出完整清單:
```
value XXX is not one of the allowed values [TIER0_STATIC, TIER0_CONNECTED, TIER0_EXTERNAL_INTERFACE,
TIER0_SEGMENT, TIER0_ROUTER_LINK, TIER0_SERVICE_INTERFACE, TIER0_LOOPBACK_INTERFACE,
TIER0_DNS_FORWARDER_IP, TIER0_IPSEC_LOCAL_IP, TIER0_NAT, TIER0_EVPN_TEP_IP, TIER1_NAT, TIER1_STATIC,
TIER1_LB_VIP, TIER1_LB_SNAT, TIER1_DNS_FORWARDER_IP, TIER1_CONNECTED, TIER1_SERVICE_INTERFACE,
TIER1_SEGMENT, TIER1_IPSEC_LOCAL_ENDPOINT, INTER_VRF_STATIC, TGW_STATIC]
```
加完後對端路由器立刻學到 `192.168.20.1/32 via <T0 uplink IP> active=true`,ping 即通。
**這比加靜態路由正確 —— 加了 TGW_STATIC 之後靜態路由就不需要了。**

### 9.5 建立 guest cluster 的最小 manifest

```yaml
apiVersion: cluster.x-k8s.io/v1beta1     # 會自動升到 v1beta2
kind: Cluster
metadata: {name: vks-cl01, namespace: <ns>}
spec:
  clusterNetwork:
    services: {cidrBlocks: ["10.96.0.0/16"]}
    pods:     {cidrBlocks: ["192.168.0.0/20"]}
    serviceDomain: cluster.local
  topology:
    class: builtin-generic-v3.3.0        # 會自動升到最新相容版(v3.6.0)
    version: v1.32.7+vmware.3-fips-vkr.1 # 要對應 KubernetesRelease
    controlPlane: {replicas: 1}
    workers:
      machineDeployments:
      - {class: node-pool, name: np1, replicas: 1}
    variables:
    - {name: vmClass,      value: best-effort-small}
    - {name: storageClass, value: vsan-default-storage-policy}
```
`machineDeployments[].class` 要用 ClusterClass 裡定義的名稱(查
`kubectl get clusterclass <cc> -n <ns> -o jsonpath='{.spec.workers.machineDeployments[*].class}'`,
本 lab 是 `node-pool`)。
