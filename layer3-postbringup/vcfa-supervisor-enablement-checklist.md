# 啟用 vSphere Supervisor(Workload Management)需求清單 — m01-cl01

> 目的:啟用 Supervisor → 才能在 VCF Automation 建 **Region** → 才能給 Org(如 TEST2)配 **Region Quota**。
> 現況:`https://vcf-m02-auto-vip.home.lab/provider/…` 被導到 **/no-supervisor**「Pre-requisites for setup are missing / No supervisors available」。
> 資料來源:2026-07-02 對 vCenter / NSX 實查。

## 依賴鏈
```
vSphere Supervisor(Workload Management on m01-cl01)
        └─ Region(對應 Supervisor + zones)
                └─ Region Quota(配給 Organization / TEST2)
```

## A. 已就緒 ✅
| 項目 | 值 | 狀態 |
|---|---|---|
| Cluster | `m01-cl01`(domain-c9),DRS+HA 已開 | ✅ |
| Datastore | `m01-cl01-ds-vsan01`(vSAN,4TB)| ✅ |
| Storage Policy | **`m01-cl01 vSAN Storage Policy`**(或 `vSAN Default Storage Policy`)| ✅ 可用 |
| Supervisor Services | cci-ns / tkg / velero 皆 **ACTIVATED** | ✅ |
| 控制平面 mgmt 網路 | `SDDC-DPortGroup-VM-Mgmt`(dvportgroup-24)| ✅ |
| 控制平面 5 連續 IP | **10.0.0.190–10.0.0.194**(實測全空;/23,gw 10.0.0.1,DNS 10.0.0.200)| ✅ 建議 |
| 控制平面大小 | **Tiny**(lab;3 台 control plane VM)| 建議 |
| DNS | Supervisor VIP DNS 記錄 → 我可在 home.lab DC 直接加 | 可代辦 |

## B. ⚠ 唯一要你決策的點 —— Workload 網路
Supervisor 的 workload 網路有三種模式,**本 lab 目前三種都缺對應基礎**(因為走了 VNA/VPC 新模式):

| 模式 | 需要什麼 | 本 lab 現況 |
|---|---|---|
| **① NSX(傳統)** | **NSX Edge Cluster + Tier-0 Gateway**(給 SupervisorLB / egress)| ❌ **無 edge cluster、無 T0**(實查)|
| **② vDS + NSX ALB(Avi)** | 部署 **Avi Load Balancer** 控制器 + Service Engine | ❌ 未部署 Avi |
| **③ VPC-based Supervisor(VCF 9 新)** | 用現有 **VNA + Distributed Transit Gateway + VPC** | 🟡 基礎有(VNA `vna-cl01`、DTG、VPC),但此路較新、需確認確切設定 |

> **建議**:VCF 9 原生方向是 **③ VPC 模式**(跟你已部的 VNA/DTG/VPC 一脈相承),不用再回頭補傳統 Edge/T0。
> 若要最穩、文件最多的傳統路,則要先 **部 NSX Edge Cluster + 建 T0**(等於再一段工程)。
> ②Avi 也可,但要多部一套 Avi。

### 走 ③(VPC)還要準備的 IP/網段(待你確認)
- **Pod CIDR**(叢集內部,預設 `10.244.0.0/20`,不對外)
- **Service CIDR**(預設 `10.96.0.0/23`,不對外)
- **Ingress / Egress**:VPC 模式由 VPC 的 external IP block(Day0 `10.0.0.0/23`)+ NAT 提供;細節待設定精靈確認
- workload namespace 網路:走 VPC subnet

## C. Content Library(TKG 映像)
- 現有 `lab-cl`(LOCAL)。
- ⚠ 要用 **VKS / TKG** 開 K8s,需 **Tanzu Kubernetes releases(TKr)映像**;offline lab 連不到 VMware 線上 repo → 需**手動匯入 OVA/TKr 到本地 content library**,或建可連外的 subscribed library。
- 若 **只做 VM Service / Region Quota 消費(不跑 K8s)**,TKr 可先不備。

## D. 決策後我會做的事(選 ③ 為例)
1. (代辦)在 home.lab DC 加 Supervisor VIP 的 DNS A 記錄。
2. VCF Operations「ENABLE SUPERVISOR IN OPS」或 vCenter Workload Management 精靈:
   - 選 m01-cl01、Tiny、storage policy、mgmt 網路(10.0.0.190–194)、VPC workload 網路。
3. 等 Supervisor Ready(~20–40 分)。
4. VCF Automation Provider:建 **Region**(綁該 Supervisor)。
5. TEST2 org → 配 **Region Quota**(CPU/記憶體/儲存額度)。

---
## ✅ 實作結果(2026-07-03)—— Supervisor 已送出部署

走 **VPC 模式** 成功啟用**單節點 Supervisor `vcf-m02-sup01`**(vCenter > Supervisor Management > GET STARTED):
- 單節點:**Enable control plane HA = OFF**;cluster m01-cl01;storage `m01-cl01 vSAN Storage Policy`。
- Mgmt:Static、`SDDC-DPortGroup-VM-Mgmt`、**10.0.0.190–194**、/23、gw 10.0.0.1、DNS/NTP 10.0.0.200、home.lab。
- Workload:NSX VPC、Default profile、Private(VPC)172.30.0.0/16、Service 172.29.0.0/16。
- 狀態:**Configuring**(約 20–40 分)。

### 🔑 關鍵雷:VPC Connectivity Profile 要開 Service Gateway(接 VNA)
Supervisor 走 VPC 時,精靈檢查 Default VPC Connectivity Profile,報 **3 個不相容**:
`servicegw.disabled` / `snat.disabled` / `edgecluster.missing`。

**原因**:Day0 只建了 VPC/DTG/VNA,但 **VPC Connectivity Profile 的 Service Gateway 沒設定**。
**解法**(NSX UI:**VPCs > Profiles > VPC Connectivity Profile > Edit**):
1. **Virtual Network Appliance Cluster** 選 `vna-cl01` → 一次修好 servicegw + edgecluster(VNA 被當成 edge_cluster_paths)。
2. **Default Outbound NAT = On** + **External IP Block = Day0 External Ip Block** → 修好 snat。
   - (UI toggle 有時點不動;可改 API PATCH:`service_gateway.nat_config.enable_default_snat=true`。)
3. 存檔後 NSX realize SUCCESS;**精靈要重載(F5)才會清掉舊的 incompatible 快取**,重選 profile 即顯示相容。

驗證:`GET /policy/api/v1/orgs/default/projects/default/vpc-connectivity-profiles/default` →
`service_gateway.enable=true`、`nat_config.enable_default_snat=true`、`edge_cluster_paths=[…/vna-cl01]`。

### 部完 Supervisor 後的下一步
1. Supervisor Ready → VCF Automation Provider 建 **Region**(綁 vcf-m02-sup01)。
2. 各 org(lab-vmapps/TEST2/vmapp)配 **Region Quota**。
3. 做 demo app(VM Service / namespace）。

---
## 🔥 深層排錯:Supervisor 卡 CONFIGURING 的真根因(2026-07-03)—— WCP 推送缺口

> 症狀:VLAN7 重配後 redeploy,supervisor 一直卡 `CONFIGURING`,k8s_status 在 ERROR/WARNING 間跳,
> 訊息輪播 `no deployments found in any zone` → `VPCNetworkConfiguration timeout`。表面像 NCP / 網路問題,**其實不是**。

### 診斷路徑(關鍵工具)
1. **拿 CP VM 密碼**:vCenter 上 `python /usr/lib/vmware-wcp/decryptK8Pwd.py` → 印出 CP VM IP(10.0.0.190)+ root 密碼。
2. **SSH 進 CP VM** 用 `KUBECONFIG=/etc/kubernetes/admin.conf` kubectl 直接看 pod。
3. 發現:**NCP 其實 `Running 2/2`(NSX ncp_health 告警是誤報)**;真凶是一串系統 pod `CrashLoopBackOff`:
   `zone-operator` → `vsphere-csi-controller`(1/7)→ `vmop` → `mobility-operator`。

### 根因鏈(一張骨牌推倒全部)
```
zone-operator crash (讀不到 vCenter 憑證 → cis/session 401)
   └→ 不建 AvailabilityZone
        └→ CSI "could not find any AvailabilityZone" crash
             └→ CSI 沒註冊 CnsNodeVmAttachment CRD
                  └→ vmop "no matches for kind CnsNodeVmAttachment" crash
                       └→ 沒 VM operator → 整個 supervisor 卡住
```

### 真根因 = **WCP 沒把幾個設定推進 supervisor**(這台歷經 VLAN7 重配+孤兒清理+redeploy,WCP 狀態有缺口)
每個 operator namespace 都該有自己的 `wcp-<op>-sa-vc-auth` 密鑰,但實查:
- `vmware-system-vmop/nsop/mobility/imageregistry/monitoring` **都有** ✓
- **`vmware-system-zoneop` 唯獨缺** ✗ → zone-operator 的 vclib 讀空憑證 → cis/session **401**(STS log 完全無紀錄=根本沒帶帳號)。

> 判別技巧:solution user 帳密(`dir-cli`/secret 內)Basic auth 測**都能登**、STS log 也顯示 auth succeeded
> → 所以 401 不是密碼錯、不是時鐘偏移(實測差 10s)、不是 STS/SSO 壞,而是**送出空憑證**。

### 三個手動修補(讓 supervisor 收斂)
```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
# ① 補 zone-operator 缺的 vc-auth 密鑰(直接複製 kube-system 內有效的 wcp-cluster-credentials)
U=$(kubectl -n kube-system get secret wcp-cluster-credentials -o jsonpath='{.data.username}')
P=$(kubectl -n kube-system get secret wcp-cluster-credentials -o jsonpath='{.data.password}')
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata: { name: wcp-zoneop-sa-vc-auth, namespace: vmware-system-zoneop }
type: Opaque
data: { username: $U, password: $P }
EOF
kubectl -n vmware-system-zoneop delete pod --all --force   # 重讀 → decommission monitor started(不再 401)

# ② 補缺的 AvailabilityZone CR(vCenter 有 vSphere Zone domain-c9,但沒推下來)
kubectl apply -f - <<EOF
apiVersion: topology.tanzu.vmware.com/v1alpha1
kind: AvailabilityZone
metadata: { name: domain-c9 }
spec: { clusterComputeResourceMoId: domain-c9, clusterComputeResourceMoIDs: [domain-c9] }
EOF
kubectl -n vmware-system-csi delete pod -l app=vsphere-csi-controller --force  # → 過 AZ 那關

# ③ CSI 換報 "supervisor-id is not set" → 補進 vsphere-config-secret 的 [Global]
#    vmware-system-csi/vsphere-config-secret 的 vsphere-cloud-provider.conf [Global] 加:
#      supervisor-id = "56f389d5-029a-49fe-acc1-b3729b0e8962"   (= 所有 wcp-*-user 名字裡的第一個 UUID)
kubectl -n vmware-system-csi delete pod -l app=vsphere-csi-controller --force  # → CSI 7/7 Running
```
結果:CSI 7/7 → 註冊 `cnsnodevmattachments` CRD → vmop 2/2、mobility 2/2 恢復 → **全部 pod Running**;
WCP 接著跑 `AddHost`(vLCM 裝 spherelet)→ core services → RUNNING。

> **`GatewayConnectionReady=False (GatewayConnectionNotSet)` 是良性**:本 lab VPC 走 **distributed-VLAN + VNA SNAT**(非 Tier-0 gateway-connection),
> NCP 那條 condition 在此拓樸本來就 False,不擋 supervisor(pod 已能起、拉 image = 南北向 SNAT 通)。要它 True 才需補 Tier-0。

> 監看:`E:\9.1\supervisor-final-watch.log`(輪詢 config_status 到 RUNNING)。

---
## (原)要你拍板的 3 件事
1. **Workload 網路走哪種?**(建議 ③ VPC;或要我先補 ①Edge/T0)
2. **要不要 K8s/VKS?**(要的話得先解決 TKr 離線映像)
3. **Supervisor VIP 的 FQDN/IP** 命名(例:`vcf-m02-sup01.home.lab`,VIP 用 10.0.0.190 那段其中一個)
