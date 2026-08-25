# VCF 9.1 Lab — Context 外部化(最後更新 2026-08-25)

> 給下一個 session 用的**現況真相源**。開場先讀這份 + repo `vcf9.1-lab/CLAUDE.md`。
> 環境會變 — 任何 IP/狀態在動手前先實測驗證,不要憑這份直接下結論。

---

## 1. 目前環境狀態(2026-08-25 重建後)

**整套 VCF 9.1 已於 2026-08-23 重建完成**(312/312 步驟成功),VCFA 於 08-25 以 Day-N 補裝完成。

| 元件 | FQDN / IP | 狀態 |
|---|---|---|
| VCF Installer | 10.0.0.71(VM `vcf-installer-verify`,在外層 vCenter) | role=VcfInstaller,bundle 16 個 |
| vCenter | vcf-m02-vc01.home.lab / **10.0.1.19** | ✅ |
| NSX Manager | vcf-m02-nsx01a.home.lab / **10.0.1.20** | ✅(VIP 是 .21,cluster 未完成前不通) |
| SDDC Manager | vcf-m02-sddcm01.home.lab / 10.0.1.18 | ✅ |
| VCF Operations | vcf-m02-ops01.home.lab / **10.0.1.22** | ✅ 部署 day-N 元件的入口 |
| Ops Collector | 10.0.1.24 | ✅ |
| VSP(fleet 基座) | vcf-m02-vsp01 / 10.0.0.172;節點 **10.0.0.227-231** | ✅ 4 節點 |
| fleet01 | vcf-m02-fleet01.home.lab / 10.0.1.23 | ✅ Host-header 路由 |
| VIDB(VCF SSO) | vcf-m02-vidb.home.lab / 10.0.0.174 | ✅ 跑在 VSP 上,非獨立 VM |
| **VCFA** | vcf-m02-auto-vip.home.lab / **10.0.0.170** | ✅ 9.1.0.0200.25556825 |
| VCFA runtime | vcf-m02-auto-platform.home.lab / 10.0.0.171;節點 **10.0.0.243** | ✅ 208 pod |
| nested ESXi ×4 | 10.0.1.14-17 | ✅ 24vCPU/256GB |
| NTP | **10.0.1.254**(RouterOS) | 🔴 bring-up 硬性需求,不可用 10.0.0.200 |
| 外層 vCenter | 10.0.0.101(pw `VMware1!`) | nested ESXi VM 在 host **10.0.0.95** |
| depot(installer 用) | http://10.0.0.48:8888 | 另有 vcf9depot 10.0.0.61(目前空) |

**密碼**:新元件一律 `VMware1!VMware1!`;外層 vCenter 是 `VMware1!`;VSP 節點用 `vmware-system-user`;
Supervisor CP 密碼用 vCenter 上 `/usr/lib/vmware-wcp/decryptK8Pwd.py`(注意結尾 **d**)取。

---

## 2. 這次(08-21~08-25)做了什麼

1. **VCFA 壞掉 → 追根因**:VIDB `ResourceGroupNotFoundException` → OIDC 404 → provisioning 403/500;
   官方 cleanup 腳本(KB 441333)需 VSP 認證,而 VSP 缺 `component=vsphere` namespace → **死結**。
2. **整套重建**:清場 → 重部 4 台 nested ESXi → bring-up(**spec 移除 `vcfAutomationSpec`**)。
3. **VCFA Day-N 補裝**:VCF Operations UI → Build → Lifecycle → VCF Management → ADD COMPONENT。
4. 產出腳本:`installer-to-depot.sh`、`fleet-trust-ca.sh`(都已推 git)。
5. 產出文件:`E:\9.1\VCF91-Rebuild-VCFA-Deployment.docx`(圖片位置預留)。

---

## 3. 🔴 這次踩到並確認的坑(最重要)

### 3.1 開關機排程會中斷 bring-up
第一次 bring-up 失敗 `PUBLIC_VSP_CLUSTER_BOOTSTRAP_FAILED / 600 秒 timeout`,
根因是**週五 23:00 的關機排程**在部署中把 NSX / SDDC Manager 關掉(前 39 步其實都成功)。

**規則**:任何 bring-up / 長時間 LCM 前先
`Disable-ScheduledTask -TaskName 'VCF-M02-Nightly-Shutdown-AllExceptVC','VCF-M02-Morning-PowerOn-FullStack'`;
排查失敗先看 `E:\9.1\shutdown-all-except-vc.log` 該時段有沒有跑過,再懷疑 etcd/timeout。

> ⚠️ **目前這兩個排程仍是 Disabled**,尚未恢復。

### 3.2 timeout 參數位置(VSP 卡關的解)
檔案 `/etc/vmware/vcf/domainmanager/application.properties`,**SDDC Manager 與 Installer 兩台都要套**:
```
vsp.bootstrap.task.timeout.minutes=240
vsp.bootstrap.command.timeout.minutes=200
vc.appliance.services.check.timeout.minutes=240
orchestrator.task.retry.max=240        # 預設 60,會 "failed after 60 retries"
nsxt.manager.wait.minutes=180
edge.node.vm.creation.max.wait.minutes=90
```
套用走 vCenter guest-ops(root 不可直接 SSH),之後 `systemctl restart domainmanager`。
一鍵:`nested-workarounds/Apply-VspRecipe.ps1 -InstallerVmPattern 'vcf-installer-verify*'`

### 3.3 inventory 的 datastore 已過時
`inventory/lab.yaml` 原寫 `vsanDatastore`(外層 vSAN 已重格、不存在),
實際 nested ESXi 在 **`ForNFS`**(5715GB)。已修正並 commit。

### 3.4 PowerCLI 不可靠 → 改用 govc
`Prepare-NestedESXi.ps1` 跑 10 分鐘無輸出。改用 `govc host.esxcli` 秒完成。
注意 esxcli 的 key 是 `/VSAN/xxx` 格式,不是 `govc host.option.ls` 看到的 `VSAN.xxx`。
OVA template 已預設 3 項,只需改:`GuestUnmap=1`、`FakeSCSIReservations=1`、`Vsan2ZdomCompZstd=0`。

### 3.5 VCFA 走 Host header 路由
直接打 IP 一律 404,**必須用 FQDN 或帶 `Host:` header**。fleet01 也是。

### 3.6 9.1 Fleet 的 CA 信任機制完全變了
不是 keytool truststore(那是舊版 / KB 316056),而是 **cert-manager trust-manager**:
```
Bundle: platform-trust (cluster-scoped)
  sources: useDefaultCAs + Secret(label trust.vmsp.vmware.com/bundle=platform-trust, key ca.crt)
  target : configmap vcf-fleet-depot/platform-trust → bundle.pem + bundle.jks
  trust-manager --trust-namespace=vmsp-platform
```
**直接改 configmap 無效**(會被覆蓋),要建帶 label 的 Secret。工具:`fleet-trust-ca.sh`。

### 3.7 Installer 的 bundle 格式 ≠ depot 格式
installer:`/nfs/vmware/vcf/nfs-mount/bundle/<UUID>/<UUID>/<檔名>`
depot:`PROD/COMP/<COMPONENT>/<檔名>`
對照在 `productVersionCatalog.json` 的 `.patches.<COMP>[].artifacts.bundles[]`(**不在** vcfManifest.json)。
轉換工具:`installer-to-depot.sh`(hardlink 模式,但**輸出必須同檔案系統**,否則退化成 cp 塞爆 tmpfs)。

### 3.8 bash `UID` 是 readonly 內建變數
拿它當迴圈變數會整個迴圈失效且統計全 0。改名(本專案用 `BID`)。

### 3.9 報狀態要交叉驗證
vCenter REST `/api/vcenter/vm` 偶爾回**過期快取**(曾回「14/14 全開」但實際是關的)。
關鍵狀態一律 **govc + REST 兩邊比對**,不要只看 log 或單次讀值。

---

## 4. VCFA Day-N 部署要點(這次驗證過)

**入口**:VCF Operations `10.0.1.22` → Build → Lifecycle → VCF Management → Components → `ADD COMPONENT` → VCF Automation

**精靈三步驟**:
| 頁 | 設定 |
|---|---|
| 1 Deployment Type | New / 9.1.0.0 / Small(24vCPU 96GB 600GB,需 5 IP) |
| 2 Parameters | IP pool `10.0.0.241-245`(選 **Individual IPs**);FQDN auto-vip(.170)、auto-platform(.171);密碼 |
| 3 Summary | 確認後 FINISH |

🔴 **硬性限制**:兩個 FQDN 解析的 IP **必須在 IP pool 之外**。用 Individual IPs 可避免 CIDR 涵蓋 .170/.171。

**時間軸參考**(nested):送出 → bootstrap 約 1.5h → VM/IP 上線 → cluster 完成(約 2h)→ 應用 pod 起來(約 3.5h)→ 服務就緒(約 4h)。

**已知**:第一次跑完 fleet 註冊步驟會 Failed(`Install/Start component using SDDC lifecycle service`,各 3 Errors),
**在任務詳情頁按 RETRY 即可完成註冊**(實測有效,component 從 9 → 10)。

---

## 5. 目前的 VCFA 功能狀態(2026-08-25 實測)

| 項目 | 結果 |
|---|---|
| `/automation/`、`/tm/login/` | 200 |
| provider 認證(`admin@system`) | ✅ |
| vCenter 整合 | ✅ `connected=true`, `mode=IAAS` |
| Orgs | 1 個(System,全新部署正常) |
| IaaS API | ✅ 200 |
| fleet component 註冊 | ✅ 已完成(UI 顯示 10 items) |

**尚未做**:租戶 Org、Region、Project、Image/Flavor mapping — 要實際部 VM 才需要設。

---

## 6. 腳本與檔案位置

| 檔案 | 用途 |
|---|---|
| `E:\9.1\vcf9.1-lab\` | 主 repo(branch `rebuild-lessons-2026-07`) |
| `layer1-nested/Deploy-NestedESXi-And-Installer.ps1` | 部 nested ESXi(`deployVCFInstaller=0`) |
| `nested-workarounds/Apply-VspRecipe.ps1` | VSP 配方(FTT0+reservations+兩台 timeout) |
| `layer2-bringup/generated-bringup-novcfa.json` | 這次用的 spec(無 VCFA) |
| `E:\9.1\tools\shutdown-all-except-vc.ps1` / `poweron-all-stack.ps1` | 開關機 |
| `E:\9.1\installer-to-depot.sh` | installer bundle → depot 格式 |
| `E:\9.1\fleet-trust-ca.sh` | Fleet 信任 private CA |
| `E:\9.1\tools\docx-build\gen-vcf-rebuild-doc.js` | 產生 Word 文件 |
| `E:\9.1\VCF91-Rebuild-VCFA-Deployment.docx` | 交付文件(圖片待補) |
| `E:\9.1\doc-shots\` | 文件圖片目錄(放 01~05.png 後重跑腳本自動嵌入) |

**另一個 repo**:`kostenyang/gg`(PRIVATE)= TSMC 專案,README 已到 §22
(§21 installer-to-depot、§22 fleet-trust-ca)。

---

## 7. 待辦

- [ ] **恢復開關機排程**(目前 Disabled)—— 恢復前先實測關機腳本能否抓到新 VCFA VM `vcf-m02-auto-platform-85xql`(規則比對 `auto-platform`,理論上可以)
- [ ] Word 文件補 5 張截圖(Chrome MCP `save_to_disk` 拿不到檔,需把 Chrome 拉前景用 PowerShell 截)
- [ ] `Downloading Esx metadata, vibs and vendor add-ons` 每日 Failed(air-gap depot 抓 vendor add-on,與 VCFA 無關)
- [ ] 使用者最終驗收:登入 `https://vcf-m02-auto-vip.home.lab/automation`(LOCAL / admin)

---

## 8. 瀏覽器操作備忘

- Chrome MCP 要用 **`switch_browser`** 讓使用者在 Chrome 擴充點 Connect,才連得到 **"LABAD"** 那台(= 本機 10.0.0.200 / KADDNS)。
  其他 Browser 1/2/4 連不到 lab 內網(導航即跳 chrome error)。
- 重建後憑證會換,要重新把新根 CA 匯入 `Cert:\LocalMachine\Root`(從 `openssl s_client -showcerts` 抓 subject==issuer 那張)。
- `save_to_disk` 存 server 端,本機拿不到 → 要圖檔得用 PowerShell 截螢幕(但會需要把 Chrome 拉前景)。
