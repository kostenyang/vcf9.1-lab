# VCF 9.1 NSX VNA + VPC 部署 — API 版

> 用 **NSX Policy REST API** 部署 Virtual Network Appliance(VNA)並串接 Distributed Transit
> Gateway(DTG)+ VPC。對應 UI 流程見 [vna-vpc-deploy-gui.md](./vna-vpc-deploy-gui.md)。
> 本 lab 實作值:home.lab / NSX 10.0.1.21 / VNA 10.0.0.181。參考:
> [sdn-warrior — VCF 9.1 VNA and VPCs](https://sdn-warrior.org/posts/vcf9.1-vna-vpc/)。

## 0. VNA 是什麼
**Virtual Network Appliance** = VCF 9.1 NSX 新元件,以**獨立 appliance VM(可叢集)**部署,
替 **VPC** 提供**有狀態服務**(NAT / LB),搭配 **Distributed Transit Gateway** 運作。
不是 Edge、不跑 T0/T1。每個 VPC 連到 DTG 後自動拿一段 `100.64.0.0/x` service subnet 做 NAT。

```
VNA cluster (stateful 引擎) ──┐
                              ├─ Distributed Transit Gateway(DTG)── External Connection(VLAN + IP block)
VPC ── VPC attachment ────────┘         │
  └─ subnets(Public/Private/Private_TGW) └─ 100.64.0.0/21 service subnet(NAT 落點)
```

## 1. 認證 & 共用變數
```powershell
$nsx = 'https://10.0.1.21'              # NSX Manager VIP
$auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('admin:VMware1!VMware1!'))
$h = @{ Authorization = "Basic $auth"; 'Content-Type' = 'application/json' }
# 所有呼叫:Invoke-RestMethod -Headers $h -SkipCertificateCheck（pwsh7,Win PowerShell 5.1 沒有此參數)
```
> curl 等價:`curl -k -u 'admin:VMware1!VMware1!' -H 'Content-Type: application/json' -X PUT ...`

## 2. 先蒐集部署 ID
| 需要 | 來源 API | 本 lab 值 |
|---|---|---|
| Compute Manager id | `GET /api/v1/fabric/compute-managers` | `fe5ec047-de57-43a6-970d-c501f24a3165`(vcf-m02-vc01)|
| Cluster moref | `GET /api/v1/fabric/compute-collections`(cm_local_id)| `domain-c9`(m01-cl01)|
| Datastore moref | vCenter `GET /api/vcenter/datastore` | `datastore-15`(vSAN)|
| Mgmt 網路 moref | vCenter `GET /api/vcenter/network` | `dvportgroup-24`(SDDC-DPortGroup-VM-Mgmt)|
| Overlay TZ path | `GET /policy/api/v1/infra/sites/default/enforcement-points/default/transport-zones` | `.../transport-zones/a555c6f4-...`(overlay-tz-mgmt-nsxt)|

## 3. 建 VNA cluster
`PUT /policy/api/v1/infra/sites/default/enforcement-points/default/virtual-network-appliance-clusters/vna-cl01`
```json
{
  "display_name": "vna-cl01",
  "appliance_form_factor": "SMALL",          // SMALL(2vCPU/4GB,lab)|MEDIUM|LARGE|XLARGE
  "service_type": "VPC_SERVICES",            // VPC_SERVICES | ROUTE_CONTROLLER
  "password_managed_by_vcf": false,          // false = 自管密碼(下方 node 提供 credentials)
  "advanced_configuration": {
    "overlay_transport_zone_path": "/infra/sites/default/enforcement-points/default/transport-zones/a555c6f4-42c6-4c7d-ab37-59a56907a3e9"
  }
}
```

## 4. 建 VNA node(觸發 appliance VM 部署)
`PUT .../virtual-network-appliance-clusters/vna-cl01/virtual-network-appliances/vna-node-01`
```json
{
  "resource_type": "VirtualNetworkAppliance",      // ⚠ 必填(多型鑑別子)
  "display_name": "vcf-m02-vna01",
  "hostname": "vcf-m02-vna01.home.lab",
  "management_interface": {
    "network_id": "dvportgroup-24",
    "ip_assignment_specs": [{
      "ip_assignment_type": "StaticIpv4",          // ⚠ 是 ip_assignment_type,不是 resource_type
      "default_gateway": ["10.0.0.1"],
      "management_port_subnets": [{ "ip_addresses": ["10.0.0.181"], "prefix_length": 23 }]
    }]
  },
  "vm_deployment_config": {
    "compute_manager_id": "fe5ec047-de57-43a6-970d-c501f24a3165",
    "cluster_or_resource_pool_id": "domain-c9",
    "datastore_id": "datastore-15"
  },
  "credentials": { "cli_password": "VMware1!VMware1!", "root_password": "VMware1!VMware1!", "audit_password": "VMware1!VMware1!" }
}
```
> ⚠ **雷**:① node 頂層要 `resource_type=VirtualNetworkAppliance` ② IP spec 的鑑別欄位是
> `ip_assignment_type`(值 `StaticIpv4`)不是 `resource_type` ③ 密碼需符合 NSX policy(≥12 字、複雜度)。
> ④ 單節點即可(本 lab),要 HA 則建第二個 node(`vna-node-02`)。

## 5. 驗證 VNA
```
GET .../virtual-network-appliances/vna-node-01/state    → configuration_state.consolidated_status = SUCCESS, progress 100
GET .../virtual-network-appliance-clusters/vna-cl01/status → status = UP, member vtep_state = VTEP_STATE_UP
```
VM 會在 inner vCenter 出現(`vcf-m02-vna01`)→ 開機 → 註冊成 edge-transport-node → ~15–25 分鐘 UP。

## 6. External Connection + IP block(VCF Day0 已建)
VCF bring-up 的 Day0 已自動建好,通常**直接沿用**:
- External IP Block:`GET /policy/api/v1/infra/ip-blocks` → `Day0 External Ip Block` = `10.0.0.0/23`(visibility EXTERNAL)
- 外部連線:`Day0 Transit Gateway Attachment`(connection_path → `distributed-vlan-connection`)掛在 Default TGW
> ⚠ 想自建專屬 external block 會被擋(不可與 Day0 的 /23 重疊;`error_code 640268`)。lab 直接用 Day0 的。

(選用)建私網 block 給 VPC subnet:
`PUT /policy/api/v1/infra/ip-blocks/vpc-priv-block` → `{ "cidr": "172.16.50.0/24", "visibility": "PRIVATE" }`

## 7. 建 VPC + attach 到 DTG
`PUT /policy/api/v1/orgs/default/projects/default/vpcs/vpc-test01`
```json
{ "display_name": "vpc-test01", "ip_address_type": "IPV4" }
```
> ⚠ **default project 下 VPC 只能極簡** —— 不能帶 service_gateway / private_ipv4_blocks / external_ipv4_blocks
> 等欄位(`error_code 610785`),這些一律繼承 project 的 default VPC Connectivity Profile。

**VPC attachment(關鍵 — 沒這步 VPC 是 isolated,建 subnet 會失敗)**
`PUT .../vpcs/vpc-test01/attachments/default`
```json
{ "vpc_connectivity_profile": "/orgs/default/projects/default/vpc-connectivity-profiles/default" }
```
attach 後 VPC 即連上 Default TGW,系統自動建 NAT(DEFAULT + USER)、可用 100.64 service subnet。

## 8. （選用）建 workload subnet
`PUT .../vpcs/vpc-test01/subnets/sub01` → `{ "access_mode": "Private_TGW", "ipv4_subnet_size": 28 }`
access_mode:`Public`(用 external block,直連)/`Private`(NAT 出去,需 VPC private block)/`Private_TGW`(經 TGW)/`Isolated`。
> ⚠ **default project 的 IP block 不適合配 workload subnet**(external /23 被 Day0 整段保留;private 對齊不符 →
> `error_code 610708/610711`)。要實際放 VM 的 workload VPC,**建議建自訂 Project(tenant)**,給它專屬、
> 對齊的 external/private IP block + connectivity profile,再於該 project 下開 VPC + subnet。

## 9. 驗證整體
```
GET /policy/api/v1/orgs/default/projects/default/transit-gateways/default     → transit_subnets 含 100.64.0.0/21
GET .../vpcs/vpc-test01/attachments/default                                   → vpc_connectivity_profile = .../default
GET .../vpcs/vpc-test01/nat                                                   → DEFAULT + USER
```

## 本 lab 實際結果
| 物件 | 值 / 狀態 |
|---|---|
| VNA cluster | `vna-cl01`(SMALL/VPC_SERVICES)**UP** |
| VNA node | `vcf-m02-vna01` / **10.0.0.181** / VTEP UP |
| DTG | Default Transit Gateway,service subnet **100.64.0.0/21** |
| External | Day0:10.0.0.0/23 + distributed-vlan-connection |
| VPC | `vpc-test01`(short_id HAbfWSmU)attach 到 default profile,NAT 就緒 |
