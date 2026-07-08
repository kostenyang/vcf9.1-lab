# VCF 9.1 nested lab 全打掉重建 — 血淚經驗 (2026-07-06/07)

> 背景：nested vSAN **FTT=0** 在反覆 hard power-cycle 下腐壞，先後吃掉 Supervisor CP VM 與 NSX manager 的單副本 vSAN 物件 → 決定裸 nested ESXi 起重建、修根因。以下是這趟撞出來的關鍵，之後重建照這份走可省數小時。

---

## 1. ⚠️ 最大地雷：installer 用錯台

- **`Deploy-NestedESXi-And-Installer.ps1` 裡 `$VCFInstallerOVA = VCF-SDDC-Manager-Appliance-*.ova` 是錯的** —— 那是 **SDDC Manager appliance**，不是 **VCF Installer**。
- 用 SDDC Manager appliance 當 installer：它連 depot 後會**把「9.1.0.0」release 解析成最新 patched BOM（0300 mix）**，然後要一堆**單獨的 fleet 服務子 bundle**（VSP/Salt/License/Fleet_LCM/SDDC_LCM…），但這些：
  - 不是下載工具的有效 `--component`（工具只認 19 個主元件）
  - depot 沒有獨立目錄 → `BUNDLE_NOT_FOUND`
  - 改 depot catalog / bump seqnum / 重開機**都沒用**（它把 BOM cache 在本機持久層）
- **正解**：用**專屬 VCF Installer appliance**（本 lab 是 `vcf-m01-cb01.home.lab-9.1`，10.0.1.4）。它的 web UI 標題就是 **"VCF Installer"**；SDDC Manager appliance 不是。
  - cb01 早已把**完整 base 9.1.0.0 BOM（含全套 fleet 服務）**下載好（bundles SUCCESSFUL 含 VSP/Salt/License/Fleet_LCM/SDDC_LCM/Telemetry/Migration base 版）。
  - 換 cb01 後 validation **一次就綠**（只剩 NTP + 容量兩個無害 WARNING）。
- **判別法**：`GET https://<ip>/` 看 `<title>` —— 要 "VCF Installer"，不是 SDDC Manager。

## 2. appliance 的 portgroup：MGMT，不是 Trunk-Nobinding

- 外層有兩種 portgroup：
  - **`Trunk-Nobinding`**：VLAN trunk，只給 **nested ESXi host**（它們 NIC 上有 `dvfilter-maclearn` fling 才在上面可達）。
  - **`MGMT`**：一般 appliance 用（depot 10.0.0.61 / DNS 10.0.0.200 / installer 10.0.1.4 都在這）。
- **把 VCF appliance 放 Trunk-Nobinding 會完全不通**（OS 設好 IP 也 ping 不到 gateway）—— MAC 沒被外層 switch 學到。放 **MGMT** 就通。
- deploy 新 installer 時 NIC 記得指 MGMT。

## 3. FTT 混合策略（治本 + VSP 能起來）

- **根因**：nested FTT=0 無備援 → 單一 vmdk 壞區 = 物件直接遺失、無法 rebuild。
- **但 FTT=1 全套也不行**：VSP / Supervisor 的 **etcd 對 fsync 延遲極敏感**，nested vSAN 上 FTT=1 雙寫延遲會讓 **VSP cluster bootstrap 失敗**：
  ```
  PUBLIC_VSP_CLUSTER_BOOTSTRAP_FAILED — Failed to bootstrap VCF services runtime
  ```
- **正解 = 混合**：
  | 元件 | FTT | 原因 |
  |---|---|---|
  | vCenter / NSX / SDDC Manager | **1** | 核心資料安全（bring-up 前 3 關就部好，天生 FTT=1）|
  | VSP / fleet / (之後) Supervisor CP | **0** | etcd 要低寫延遲才 bootstrap 得起來 |
- **做法**：bring-up 到第 4 關(NSX)後、第 5 關(VSP)**失敗當下**，把 inner vCenter (10.0.1.19) 的 `vSAN Default Storage Policy` 設 **FTT=0 + forceProvisioning**（`Set-VsanFtt0.ps1 -Vc 10.0.1.19`），再 retry → VSP 用 FTT=0 部起來；核心已部好的維持 FTT=1。

## 4. bring-up retry 程序（VSP 失敗後）

1. **設 FTT=0**：`pwsh Set-VsanFtt0.ps1 -Vc 10.0.1.19 -Password VMware1!VMware1!`
2. **刪掉失敗殘留**（會佔住 vspClusterSpec.ipv4Pool 10.0.0.226-240 的 IP，不刪 retry 會 `QUICK_START_VALIDATION_FAILED: IP in-use`）：
   - inner vCenter 上刪 `vcf-m02-vsp01-*`（4 節點 VSP cluster）
   - 刪 `bootstrap-vm-*`（VSP bootstrap 殘留，佔 10.0.0.226）
3. **retry**：`PATCH https://<installer>/v1/sddcs/{sddcId}` body = 完整 generated-bringup.json
   - （不是 `{"action":"RETRY"}`；OpenAPI 寫明 PATCH /v1/sddcs/{id} 的 body 就是 SddcSpec）
   - **不要用 `POST /v1/sddcs` 重送** → 那是全新一輪、會撞 IP 衝突

## 5. Depot / 版本備忘

- depot server 10.0.0.61：nginx，**HTTPS auth**（vcfdepot / VMware1!VMware1!）+ **HTTP no-auth :8888**（installer 綁這個，URL 用 **IP** 不要 FQDN，見 `Connect-OfflineDepot.ps1`）。
- **9.1.0.0300 是 patch-only、不能 fresh-install**（下載工具 `--vcf-version=9.1.0.0300 --automated-install` 回空）；fresh 只能裝 base 9.1.0.0，之後 LCM 升 patch。
- 下載工具是 **VCFDT** component（可下新版）；本 lab 現有的是 9.0.2.0（能抓 9.1 主 appliance，但 fleet 服務子元件要靠對的 installer/流程展開）。
- ESX_HOST base 9.1.0.0 = build **25370933**（＝ Nested_ESXi9.1.0.0 OVA 的版本，host 不用升就符合 base 目標）。

## 6. 其它 nested 眉角（沿用）
- 4 台 nested ESXi 從**同一 OVA** 部 → **system UUID 會 regenerate 成唯一**(vSAN node identity OK)，但 **OSData VMFS-L UUID 共用**(`6a04fffe…`，良性)。
- Prepare 的 6 個 vSAN advanced settings 照 `layer1-nested/README.md`。
- **少 hard power-cycle**：這次腐壞的真正觸發是排錯時反覆硬重開機 + FTT=0 疊加。走 VCF LCM 優雅操作可大幅降風險。
