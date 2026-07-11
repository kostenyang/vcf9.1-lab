# VCFA(VCF Automation)串 NSX VPC / VNA — 現況與設定路線

> 用 VCFA Provider Management UI(`https://vcf-m02-auto-vip.home.lab/provider/`,admin/VMware1!VMware1!)
> 檢視 NSX VNA/VPC 整合。2026-06-29。截圖見對話紀錄(Provider console 各畫面)。
> ⚠ VCFA UI 只能從 **lab 網段內的機器**開(home.lab 內部);ingress 要用 **FQDN**(裸 IP 404)。

## 一、已確認 ✅ — VCFA 已與 NSX 聯邦,看得到我部的 VNA
**Provider Management > Infrastructure > Networking > Edge/VNA Clusters > VNA Clusters** 頁顯示:

| Name | Health | Nodes | Organizations | Region |
|---|---|---|---|---|
| **vna-cl01** | **Healthy** ✓ | 1 | 0 | – |

→ 我用 NSX Policy API 部的 VNA `vna-cl01` **自動同步進 VCFA、狀態 Healthy**。
這證明 **VCFA↔NSX 網路整合是通的**;只差把它**指派給 Region / Organization** 才能被租戶消費。

## 二、目前 VCFA 基礎設施狀態(Infrastructure Overview)
| 項目 | 數量 | 說明 |
|---|---|---|
| Organizations | 4 | lab-vmapps、System、TEST2、**vmapp**(2026-07-02 新建,id `…a42f63d2`,cloudapi `POST /cloudapi/1.0.0/orgs`,Enabled)|
| Regions | 0 | **尚未建 Region**(自助消費的核心)|
| Supervisors | 0 | **尚未有 workload Supervisor** ← 建 Region 的前置 |
| vCenter | 已連 | `vcf-m02-vc01.home.lab` 連線 Succeeded |
| External IP Blocks | 0 | VCFA 這層要另建(NSX Day0 的 10.0.0.0/23 不會自動同步進 VCFA)|

畫面提示:「Pre-requisites for setup are missing」/「No supervisors available」。

## 三、要讓「租戶自助開 VPC/VM」還需要的步驟(路線圖)
VCFA Provider「Get Started」精靈 + Networking 選單對應如下:

```
0. 前置:在 vCenter 啟用 vSphere Supervisor(Workload Management)← 大工程,獨立設定
        （把 m01-cl01 加進 zone、配 storage policy / 網路)
1. Create Region      Infrastructure > Regions > Create
                      → 選 Supervisor(s) + 網路資源
2. 網路綁定           Infrastructure > Networking
   - External IP Blocks   建對外 IP 區段(VPC SNAT/Public 用）
   - External Connections 建對外連線（接 NSX DTG / VLAN)
   - Edge/VNA Clusters     把 vna-cl01 指派到 Region（提供 VPC 有狀態服務）
   - Subnets               VPC 子網
3. Create Organization  Infrastructure > Organizations > Create（租戶）
4. 指派 Region 存取 + Quota 給 Organization
5. 租戶在其 Project 內自助建 VPC + 部 VM → 自動走 vna-cl01 的 NAT / 100.64 service subnet
```

## 四、關鍵結論
- **「VCFA 有沒有用/串 NSX VPC?」→ 網路整合層面:是,VNA 已在 VCFA 內、Healthy。**
- **「租戶能不能自助開 VPC?」→ 還不行** —— 缺 Region、Supervisor(Workload Management)、Org 指派。
  其中 **啟用 vSphere Supervisor 是最大的前置工程**(需規劃 storage policy / namespace 網路)。
- NSX 層的 VNA + DTG + VPC(vpc-test01)已完成(見 `vna-vpc-deploy-api.md` / `-gui.md`)。

## 五、存取備忘
- VCFA UI:只能從 lab 網段內 Chrome 開(本次用連到 lab 的那台 Chrome = "Browser 3")。
- Provider API:`POST /cloudapi/1.0.0/sessions/provider`,Basic `admin@system:VMware1!VMware1!`,
  Accept `application/json;version=40.0`,**必須用 FQDN**。
- 基礎設施/VPC 設定 UI 在 `/provider/` → Infrastructure;對應 IaaS API 在 `/iaas/api`(auth 走 VIDB OAuth,較複雜,建議 UI 操作)。
