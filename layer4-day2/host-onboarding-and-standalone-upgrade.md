# 單台 ESXi 納管 VCF → 升級測試 (session state)

> 開始 2026-09-08。使用者需求：
> 1. **測試 A**：把一台單獨 ESXi commission 進 VCF，建成**單主機叢集**，驗證能不能**正常升級 9.1.0 → 9.1.1**
> 2. **測試 B**：測試「**帶著（開機中的）VM** 的主機要進 cluster」該怎麼處理

## 起點事實（2026-09-08 實測）

| 項目 | 值 |
|---|---|
| 管理域 | `m01` id=`a53df574-d2d5-4906-a9a8-80d15608f501`，只有 1 個叢集 |
| 叢集 | `m01-cl01` id=`6a898ac1-0cff-4189-8631-8c7213a16363`，4 host，primaryDatastoreType=**VSAN**，isDefault=true |
| SDDC Manager | 10.0.1.18 — **9.1.1.0.25713928**（已升） |
| vCenter | vcf-m02-vc01.home.lab 10.0.1.19 — **9.1.1.0.25712839**（已升） |
| NSX | vcf-m02-nsx01.home.lab — **9.1.0.0.25318225**（未升，dataplane PENDING） |
| ESXi ×4 | 10.0.1.14-17 — **9.1.0.0200.25557999**（未升，HOST bundle AVAILABLE） |
| future release | **9.1.1.0** 已可見 → 升級素材在 depot 且 catalog 已推進去 |
| nested host VM | 外層 vC 10.0.0.101 → vApp `/Datacenter/vm/VCF/Nested-VCF9-M02-hFuSZOIr`，實體 host **10.0.0.95**（1023GB RAM，用 463GB） |
| 外層 datastore | `ForNFS` free 2017GB |
| nested VM 規格範本 | 24vCPU/256GB、4×NIC 在 **dvportgroup-14541**、disk 32/100/1000GB thin、guestId=vmkernel8Guest、hw vmx-20 |
| 開關機排程 | Nightly-Shutdown / Morning-PowerOn 皆 **Disabled**（另有 `VCF-M02-PowerOn-Sun0816-Once` Ready）|
| 可用 IP | 10.0.1.5, .7-.13 皆無回應 |

## 規劃

### esx05（測試用新主機）
- FQDN `vcf-m02-esx05.home.lab` / **10.0.1.13**（DNS A+PTR 待建於 10.0.0.200）
- VM 名 `vcf-m02-esx05-91`，放同一個 vApp、host 10.0.0.95、datastore ForNFS
- 網路 dvportgroup-14541（Trunk-Nobinding，mgmt untagged）
- ⚠ 部完要 toggle portgroup promiscuous/forged/mac-changes（已知坑）

### 執行順序（一台 host 跑完兩案）
1. 部 esx05 → 上面建一台**開機中的 VM** → 試 commission ⇒ **測試 B 前半：看 VCF 擋在哪**
2. 清掉 VM → commission 乾淨 host ⇒ **測試 A 前半**
3. 用 esx05 建**單主機叢集** ⇒ 驗證 VCF 允不允許 1-host cluster（storage 型態待定：vSAN 單節點 vs NFS 10.0.0.60）
4. 對該叢集跑 **9.1.0 → 9.1.1 ESX 升級** ⇒ 測試 A 主體
5. 回頭做 **測試 B 後半**：帶 VM 的主機進 cluster 的正解（VCF Import / 先遷移再 commission / vMotion 回填）

## 進度
- [x] 查清起點事實
- [ ] 建 DNS
- [ ] 部 esx05
- [ ] 測試 B 前半（帶 VM commission）
- [ ] commission 乾淨 host
- [ ] 建單主機叢集
- [ ] 升級 9.1.1
- [ ] 測試 B 後半

## 坑 / 發現
（隨做隨記）

---

## 實測結果 A：commission 一台「帶著 VM 的單機 ESXi」

環境：`vcf-m02-esx05.home.lab` / 10.0.1.13，ESXi **9.1.0.0 GA build 25370933**（Nested OVA 範本原樣），
上面刻意做出「髒」狀態：local VMFS `esx05-local`(60GB) + `legacy-app01`(**開機中**) + `legacy-app02`(關機)。

commission validation：`POST /v1/hosts/validations`，body 是**裸陣列**（不是 `{hostCommissionSpecs:[...]}`，
包起來會 400 `ANNOTATIONS_MISMATCH`）。

### 擋點 1：vmk0 只能有 Management tag
```
Host must have only Management tag enabled on the VMkernel network interface,
found more than one tag or non Management tag..
```
Nested ESXi OVA 範本預設 vmk0 = `VSAN, Management, VMotion` 三個 tag。
解法：
```
esxcli network ip interface tag remove -i vmk0 -t VSAN
esxcli network ip interface tag remove -i vmk0 -t VMotion
```

### 擋點 2：🔴 ESXi build 必須「完全等於」VCF 目前的 BOM 版本
```
Host ESXi version - 9.1.0.0.25370933 is not supported.
VCF supported ESXi versions - [9.1.0.0200.25557999]
```
**這是本測試最重要的發現之一**：VCF commission 不接受比 domain 舊（或新）的 ESXi build，
支援清單只有**單一個** build。客戶手上任何一台既有 ESXi，版本幾乎不可能剛好等於 VCF BOM，
→ **一定要先手動把該主機升到 VCF 目前的 ESX build，才可能 commission**。

> 註：本 lab 的 `9.1.0.0200.25557999` 是先前 session 手動升過的 off-BOM build，
> 所以支援清單反映的是「domain 現況」而不是原始 9.1.0.0 GA 的 25370933。

### 尚未觸及的擋點
validation 是**逐項短路**的（一次只回一個 error），所以「主機上有開機中的 VM」這一項
**還沒被檢查到** —— 要先解掉版本問題才會走到。

### 擋點 2 的解法（實測有效）
從離線 depot 抓對應 build 的 offline bundle，用 esxcli 就地升到 BOM 版本：
```bash
# depot 上檔案：/depot/PROD/COMP/ESX_HOST/VMware-ESXi-9.1.0.0200.25557999-depot.zip
#   HTTP 免認證入口是 :8888（80/443 會 401）
esxcli network firewall set --enabled false      # 8888 不在 httpClient ruleset 內
cd /vmfs/volumes/<local-ds> && wget -q http://10.0.0.61:8888/PROD/COMP/ESX_HOST/VMware-ESXi-9.1.0.0200.25557999-depot.zip -O esx0200.zip
# 進 maintenance mode 後：
esxcli software profile update -d /vmfs/volumes/<local-ds>/esx0200.zip \
  -p ESXi-9.1.0.0200-25557999-standard --no-hardware-warning
reboot
```
坑：
- 🔴 **ESXi 9 的 `esxcli software profile update` 不再吃遠端 URL**
  （`Only server local file path is supported for offline bundles`）→ 一定要先把 zip 下載到主機本地。
- nested 環境 CPU 不在支援清單 → 需要 `--no-hardware-warning`。
- 升完 20 秒內回來（nested，restart 很快）；vmk0 tag 的修改能存活重開機。

---

## 實測結果 B：🔴「帶著 VM 的主機」到底擋在哪（本測試的核心答案）

主機升到 BOM 版本後重跑 validation，逐步剝洋蔥：

| 主機狀態 | validation 結果 |
|---|---|
| `legacy-app01` **開機中** + `legacy-app02` 關機 + local VMFS | ❌ `One or more VMs found on host.` |
| 兩台 VM **都關機** + local VMFS | ❌ `One or more VMs found on host.` |
| 兩台 VM **unregister**（**vmdk 檔案仍留在 local VMFS**）+ local VMFS 還在 | ✅ **SUCCEEDED** |

### 結論（可直接講給客戶）
1. **關機沒有用**。VCF 檢查的是「主機 inventory 裡有沒有 VM 物件」，不是電源狀態。
2. **不必刪資料**。只要把 VM 從主機 inventory `unregister`，
   **VM 檔案可以原封不動留在原本的 local datastore**，commission 就會過。
3. 因此「帶著 VM 的主機進 VCF」的標準作法是：
   `關機 → unregister（保留 vmdk）→ commission → 加入 cluster → 再 register 回來`
   —— ⚠️ 但**前提是那顆 local datastore 的磁碟不會被 vSAN 宣告吃掉**，這點下一段實測。

---

## 實測結果 C：commission 成功，但 🔴 **VCF 不允許單主機叢集**

### commission（乾淨後）
`POST /v1/hosts`（一樣是裸陣列）→ 任務 `28a54773-...` **Successful**，
esx05 進 inventory 狀態 `UNASSIGNED_USEABLE`、`esxiVersion 9.1.0.0200.25557999`。
commission 過程會自動：裝暫時憑證、關 lockdown、建 ESXi service account、設 DNS/NTP、
輪換 SSH key、**關掉 SSH**、把 root 憑證存進 SDDC Manager credential store。

### 建 1 台主機的叢集 → 被產品規則擋死
`POST /v1/clusters/validations`：

| 儲存型態 | 錯誤 |
|---|---|
| vSAN，1 台 | `INVALID_NUMBER_OF_HOSTS`：**Number of hosts is less than expected. Actual 3, Provided 1** |
| NFS（外部儲存），1 台 | `INVALID_NUMBER_OF_MINIMUM_HOSTS`：**Minimum 2 hosts are required for vLCM cluster with external storage to be created.** |

> **結論：VCF 9.1 的最小叢集規模 = vSAN 3 台 / 外部儲存 2 台。單主機叢集無法建立**，
> 這是 SDDC Manager 的硬性 spec validation，不是暫時性錯誤。

### 順帶測出來的其他規則（建叢集時會一起檢查）
- `DEPLOY_WITHOUT_LICENSE_KEYS_MUST_BE_TRUE_GIVEN_VCENTER_SERVER_VERSION`
  — 9.1 走 License Hub，spec 不能帶 license key（`deployWithoutLicenseKeys` 放在 clusterSpec 內仍被判定未設，
  推測要放在**更上層**，待驗）。
- `DM_CLUSTER_LCM_VLCM_IMAGE` — 新叢集**一定要**給 `clusterImageId`（vLCM image 管理）。
- `CLUSTER_IMAGE_ESXI_VERSION_NOT_VALID` — 現有 personality `Management-Domain-ESXi-Personality`
  是 **9.1.0.0.25370933**，但相容 BOM 是 **9.1.0.0200.25557999** → 手動升版造成的 image 與 BOM 脫節，
  要建新叢集得先重新產生 cluster image。
- `HOST_NOT_COMMISSIONED_FOR_GIVEN_STORAGE_TYPE` — commission 時選的 storageType（本例 VSAN）
  **決定了這台主機能加入什麼儲存型態的叢集**，要換得重新 commission。
- `SPEC_VALIDATION_NETWORK_NOT_FOUND` / `SDDC_MANAGER_NETWORK_NOT_FOUND_ON_HOST`
  — 用 NFS 就得在 network pool 內加一個 NFS network。

### 過程中順手修掉的
network pool `m01-np01` 的 **VSAN IP 已用盡**（192.168.14.1-4 全被 esx01-04 佔用），
加第 5 台前必須擴：`POST /v1/network-pools/{id}/networks/{netId}/ip-pools`
→ 已擴 VSAN `192.168.14.5-10`、VMOTION `192.168.13.10-15`。

### PowerShell 坑
`$PID` 是唯讀內建變數（跟 bash 的 `$UID` 同一類陷阱），拿來當變數名會整段炸掉。

---

## 轉向：改成「單台掛在外面，從 vCenter 升」（使用者指示）

既然 VCF 不允許單主機叢集，改測：**主機不進 VCF 叢集，只掛在 vCenter 底下當獨立主機，從 vC 升級**。

### 已完成
1. `DELETE /v1/hosts`（body 要用 **`[{"fqdn":...}]`，不是 `id`**，用 id 會 400 `Decommission specification is invalid`）
   → esx05 已 decommission，SDDC Manager 回到 4 台。
2. `govc host.add -folder /m01-dc01/host` → esx05 以**獨立主機**身分掛進 nested vCenter
   （路徑 `/m01-dc01/host/vcf-m02-esx05.home.lab/`，MoRef **`host-3006`**）。
   > 這座 vCenter 本來就有非 VCF 管的主機（`m01-cl02/vcd-esx01.home.lab`，VCD 測試留下的），所以並非首例。

### 關鍵發現 1：vSphere 9.1 的獨立主機**確實**能用 vLCM image 管
```
GET /api/esx/settings/hosts/host-3006/software
→ base_image.version = 9.1.0.0200.25557999   (display_name ESXi)
```
→ 獨立主機有自己的 desired image，可以 draft / scan / remediate，跟叢集一樣。

### 關鍵發現 2：🔴 但 vLCM depot 目前**沒有 9.1.1 的 base image**
```
GET /api/esx/settings/depot-content/base-images
→ 9.1.0.0200.25557999 / 9.1.0.0.25370933 / 8.0.3-0.70.24674464 / 8.0.3-0.65.24659227
```
所以「從 vC 升 esx05 到 9.1.1」現在按不下去 —— 缺的是 **image 來源**，不是功能。

### 為什麼 depot 裡沒有 9.1.1（追到根因）
| 層 | 事實 |
|---|---|
| VCF depot catalog | `productVersionCatalog.json` 的 `patches.ESX_HOST[]`，9.1.1.0.25714478 的 artifacts **只有 ISO**（`VMware-VMvisor-Installer-9.1.1.0.25714478.x86_64.iso`），**沒有 `-depot.zip`** |
| SDDC Manager bundle | `/nfs/vmware/vcf/nfs-mount/bundle/8a642e37…/` 裡也**只有那個 ISO**（699MB, downloadStatus SUCCESSFUL）|
| vCenter online depot | 指向 `https://vcf-m02-sddcm01.home.lab/vmware/vcf/umds/patch-store/hostupdate/__hostupdate20-consolidated-index__.xml` —— SDDC Manager 的 UMDS store，目前**找不到任何 25714478 的檔案**（VCF 要真的跑升級才會把 ISO 轉成 image 發佈到這裡）|
| ISO 內容 | 是可開機安裝媒體（`b.b00`/`imgdb.tgz`/`*.v00`），**不是 vLCM 能直接吃的 depot zip** |

> 先前 session 之所以能做 OOB vLCM 升級，是因為手上有 **Broadcom portal 下載的 offline bundle zip**：
> `C:\vcf-archive\old-media-9.1.0\VMware-ESXi-9.1.0.0.25370933-depot.zip` / `…0200.25557999-depot.zip`，
> 用 `http://10.0.0.200:8899/` 掛成 vLCM 的 PULL offline depot
> （vCenter 裡還留著兩筆：`dryrun GA offline bundle`、`OOB vLCM upgrade test 0200`）。
> **9.1.1 的 depot zip 目前手上沒有。**

### 所以「一台掛在 vCenter 外面的單機 ESXi」可用的升級方式共 4 條
| # | 方式 | 現況可行性 |
|---|---|---|
| 1 | **vLCM image（從 vC，最正規）** | 功能可用，**缺 9.1.1 base image**。取得 image 有三條路：(a) 讓 VCF 先升 m01-cl01 的 ESX → SDDC Manager 自動把 9.1.1 發佈到 UMDS store → vC depot 就有；(b) 從 Broadcom portal 抓 `VMware-ESXi-9.1.1.0.25714478-depot.zip`，用 HTTP 掛成 offline depot（照先前 8899 的做法）；(c) `vcf-download-tool esx download`（同步整個 ESX vLCM depot，**無版本過濾**，量大，depot 只剩 78GB） |
| 2 | **esxcli software profile update + 本機 offline bundle zip** | ✅ **本次已實測成功**（9.1.0.0 GA → 9.1.0.0200）。升 9.1.1 一樣缺 zip |
| 3 | **ESXi ISO 互動式 Upgrade** | ✅ 立刻可做 —— **9.1.1 ISO 已經在 depot 上**，掛 CD 開機選 Upgrade（nested VM 很好做） |
| 4 | **VCF / SDDC Manager LCM** | ❌ **不適用**。主機不屬於任何 domain / cluster，VCF 的升級單位是 domain+cluster，不會碰它 |

---

## 🔴 卡點：9.1.1 的 ESX image 拿不到（雞生蛋問題）

使用者選「先跑 VCF m01 的 ESX 升級 → 讓 SDDC Manager 把 9.1.1 image 發佈出來 → 再套到 esx05」。
實際送 API 時撞到一連串規則：

```
POST /v1/upgrades  resourceType=DOMAIN
  → 400 UPGRADE_SPEC_INVALID_RESOURCE_TYPE: expected CLUSTER
POST /v1/upgrades  resourceType=CLUSTER
  → 500 UPGRADE_PRECHECK_VLCM_CLUSTER_WITHOUT_PERSONALITY
       "vLCM is enabled for clusters …, ESX clusters upgrade should be requested with personality"
```

也就是 **vLCM 叢集的 ESX 升級必須帶 personality（cluster image）**，而 personality 的 base image
必須存在於 vCenter 的 vLCM depot —— 但 depot 裡沒有 9.1.1。**死循環。**

### 現有 personality（證據）
| id | 名稱 | base image | 匯入時間 |
|---|---|---|---|
| dfbe3953… | Management-Domain-ESXi-Personality | 9.1.0.0.25370933 | 2026-08-27 |
| 67a755f7… | autogen-software-spec-1 | 9.1.0.0200.25557999 | 2026-09-04 |

→ personality 是**從 vCenter 叢集的 image 反向匯入**產生的，不是從 VCF bundle 生出來的。

### SDDC Manager 的 UMDS patch store 也只有舊版
`/nfs/vmware/vcf/nfs-mount/umds/patch-store/hostupdate/vmw/` 只有兩組 metadata zip 與
`9.1.0-0.25370933` / `9.1.0-0200.25557999` 的 VIB，**沒有任何 25714478**。

### 想從 Broadcom 直接抓 ESX vLCM depot → 403
```
vcf-download-tool esx metadata --depot-store=… --depot-download-activation-code-file=…
  舊 code(/root/activation-code.txt, 7/11) → ERROR: activation code 無效
  新 code(E:\9.1\actcode.txt, 9/2)         → 認證過了，但四個 depot index 全部 HTTP 403
     https://dl.broadcom.com/PROD/COMP/ESX_HOST/{main,addon-main,iovp-main,vmtools-main}/vmw-depot-index.xml
```
（`curl` 直打同樣 403 → 是**下載入口的權限/entitlement**問題，不是網路問題。）

### 🔑 唯一還沒被擋死的路：host seeding
vCenter 的 offline depot 清單裡本來就有一筆證據：
```
F8BF0484… "Extract depot offline import"  source_type=PULL
location = https://vcf-m02-esx01.home.lab/cgi-bin/host-seed.cgi?path=/var/vmware/lifecycle/hostSeed/OfflineBundle-2026-08-27--07.14.zip
```
→ **vLCM 可以「從一台已經是該版本的主機」把 image 反抽進 depot**（先前 0200 就是這樣進來的）。

所以可行順序是：
1. 用**手上就有的 9.1.1 ISO** 把 esx05（獨立主機）升到 9.1.1
2. 用 host seeding 把 esx05 的 image 匯進 vCenter 的 vLCM depot
3. depot 有了 9.1.1 base image → 建 VCF personality → 才跑得動 VCF 的叢集 ESX 升級

---

## 🔑 突破：depot zip 其實抓得到 —— token 要放在 URL **path** 裡

先前 403 的原因不是 entitlement，是**認證方式錯了**。VCF depot 的下載 token
（`E:\9.1\.broadcom-token`，也就是 `My-VcfDepot.ps1 -TokenFile` 用的那把）
是**嵌在 URL 路徑**裡的，不是 header：

```
https://dl.broadcom.com/<TOKEN>/PROD/COMP/ESX_HOST/<檔名>
```

實測：
```
main / addon-main / iovp-main / vmtools-main  的 vmw-depot-index.xml  → 全部 200
VMware-ESXi-9.1.1.0.25714478-depot.zip                                → 200
   content-length: 712837308,  前 4 bytes = PK\x03\x04（真的是 ZIP）
```

🔴 **重點發現：`productVersionCatalog.json` 只列 ISO，但同一個目錄下的 `-depot.zip` 是存在的、
只是 catalog 沒有列出來。** 所以 air-gap 環境要拿 ESX offline bundle，
**不要只信 catalog / download tool**，直接用 token 打檔名即可。

（對照：`vcf-download-tool esx metadata` 走的是**沒有 token 的**
`https://dl.broadcom.com/PROD/COMP/ESX_HOST/...`，所以一路 403。）

### 匯入 vLCM depot
```bash
# 1. 下到離線 depot（20 秒）
curl -o /depot/PROD/COMP/ESX_HOST/VMware-ESXi-9.1.1.0.25714478-depot.zip \
  https://dl.broadcom.com/<TOKEN>/PROD/COMP/ESX_HOST/VMware-ESXi-9.1.1.0.25714478-depot.zip
```
```
# 2. 註冊成 vCenter 的 PULL offline depot
POST /api/esx/settings/depots/offline?vmw-task=true
{ "source_type":"PULL",
  "location":"http://10.0.0.61:8888/PROD/COMP/ESX_HOST/VMware-ESXi-9.1.1.0.25714478-depot.zip",
  "description":"ESXi 9.1.1 offline bundle" }         → task SUCCEEDED
```
```
# 3. 驗證
GET /api/esx/settings/depot-content/base-images
→ 9.1.1.0.25714478 ✅ / 9.1.0.0200.25557999 / 9.1.0.0.25370933 / 8.0.3 ×2
```

---

## 從 vCenter 用 vLCM 升級「獨立主機」esx05（完整步驟）

### 1. 把 VM 註冊回主機（測試 B 的收尾）
```
govc vm.register -host <hostpath> -pool <hostpath>/Resources -ds esx05-local legacy-app01/legacy-app01.vmx
```
兩台都從**原本的 vmdk** 掛回來，開機驗證正常 → 證實
「關機 → unregister → 主機納管 → register 回來」整條路 VM 資料完好。

### 2. 設定 desired image（純 API，可自動化）
```
POST /api/esx/settings/hosts/host-3006/software/drafts                     → draft id
PUT  /api/esx/settings/hosts/host-3006/software/drafts/<d>/software/base-image  {"version":"9.1.1.0.25714478"}
POST /api/esx/settings/hosts/host-3006/software/drafts/<d>?action=commit&vmw-task=true   → SUCCEEDED
GET  /api/esx/settings/hosts/host-3006/software/compliance
     → NON_COMPLIANT, current 9.1.0.0200.25557999 → target 9.1.1.0.25714478
        impact=REBOOT_REQUIRED, Quick Boot 支援
```

### 3. 🔴 API 走不完最後一哩：EULA
```
POST /api/esx/settings/hosts/host-3006/software?action=apply&vmw-task=true
→ 500  com.vmware.vcIntegrity.lifecycle.eula.NotAccepted
       "The operation cannot proceed since the VMware End User License Agreement (EULA) has not been accepted."
```
**vAPI 528 個服務裡沒有任何 eula / agreement / license 服務**（實際列出來確認過），
`/api/esx/settings/eula` 等路徑全 404 → **只能從 vSphere Client UI 接受**。
UI 位置：主機 → Updates → Image → **REMEDIATE** → 對話框底部
「I accept the **Foundation Agreement**」+ START REMEDIATION。

### 瀏覽器自動化的坑（vSphere 9 UI）
🔴 **vSphere 9 的 vLCM 面板內容在 closed shadow DOM 裡**：
- `document.getElementsByTagName('iframe').length === 0`（不是 iframe）
- 遞迴走 51 個 open shadowRoot 也找不到 REMEDIATE，`innerHTML.indexOf('REMEDIATE') === -1`
- `/json/list` 也只有一個 page target
→ 任何 `querySelector` / `clickText` 類的做法都無效，
**只能用座標點擊**（`Input.dispatchMouseEvent`，viewport 1676×920、devicePixelRatio=1，截圖與 CSS 座標 1:1）。

### ✅ 結果：獨立主機 esx05 從 vCenter 升級成功
```
21:04:37  START REMEDIATION（勾 Foundation Agreement）
21:12     API 短暫 UNAVAILABLE（主機重開）
21:13:01  status=COMPLIANT  current=9.1.1.0.25714478
```
**耗時約 8.5 分鐘**（nested + Quick Boot）。

驗證：
```
govc host.info → VMware ESXi 9.1.1.0.25714478
退出維護模式 → legacy-app01 / legacy-app02 兩台都開機成功，仍在 esx05
esx05-local (VMFS 59.8GB) 完好
```

> 🔑 **對使用者問題的直接回答**：一台單獨的 ESXi 主機掛在 VCF 的 vCenter 底下（不屬於任何 VCF 叢集），
> **可以正常用 vLCM 升級**，而且流程與叢集一樣（desired image → compliance → remediate）。
> VCF/SDDC Manager 不會管它，升級責任回到 vCenter。

---

## 總結（回答使用者的兩個問題）

### Q1「單台 ESXi 加到 VCF 裡面能不能正常升級？」
分兩種納管方式，答案不同：

| 納管方式 | 能不能加？ | 誰負責升級？ | 實測結果 |
|---|---|---|---|
| 進 VCF 叢集（commission + 加入 cluster） | 可以，但**不能自己成一個叢集**（vSAN≥3 / 外部儲存≥2） | SDDC Manager（domain+cluster 為單位） | 加入既有叢集才跑得動；且 commission 前主機 build 必須先手動升到 VCF BOM |
| 掛在 vCenter 底下當**獨立主機**（不進叢集） | 可以 | **vCenter / vLCM**，VCF 完全不管 | ✅ **實測 9.1.0.0200 → 9.1.1 成功，8.5 分鐘** |

**四種可用的升級方式**（獨立主機）：
1. **vLCM image**（最正規，可 API 自動化到 commit，最後 apply 卡 EULA 要 UI）← 本次採用
2. `esxcli software profile update` + 本機 offline bundle zip ← 本次也實測過（GA→0200）
3. ESXi ISO 互動式 Upgrade
4. ~~VCF / SDDC Manager LCM~~ ❌ 不適用

### Q2「帶著（開機中的）VM 的主機要進 cluster 怎麼處理？」
```
關機 → unregister（vmdk 原封不動留在 local datastore）→ commission → 加入叢集 → register 回來
```
- 🔴 **關機不夠**，VCF 檢查的是 inventory 有沒有 VM 物件
- ✅ **不必刪資料**，unregister 就過
- ✅ 實測 register 回來後兩台 VM 都正常開機，local VMFS 完好
- ⚠️ 前提：那顆 local datastore 的磁碟不會被 vSAN 宣告（本次 esx05 的 60GB VMFS 磁碟因已格式化，
  SDDC Manager 的 `storage.disks` 根本不列它，只列 100GB + 1000GB 兩顆空碟）

## 現況（2026-09-08 收尾）
- `vcf-m02-esx05.home.lab` / 10.0.1.13 = **ESXi 9.1.1.0.25714478**，獨立主機掛在 `/m01-dc01/host/`
- `legacy-app01` / `legacy-app02` 開機中，在 esx05 的 `esx05-local` VMFS 上
- vCenter vLCM depot 已有 **9.1.1.0.25714478** base image（PULL depot 指向 10.0.0.61:8888）
- m01-cl01 仍是 4 台 @ 9.1.0.0200；SDDC Manager 9.1.1、vCenter 9.1.1、NSX manager 9.1.1 但 product_version 仍顯示 9.1.0（dataplane 未升）
- network pool `m01-np01` 已擴 VSAN `192.168.14.5-10`、VMOTION `192.168.13.10-15`
- 開關機排程仍為 Disabled

## 未完成
- [ ] VCF 叢集 ESX 升級（m01-cl01 → 9.1.1）：需要一份 base=9.1.1 的 **personality**。
      已從 esx05 匯出 image JSON（`E:\9.1\esx05-911-software-spec.json`，內容就是 `{"base_image":{"version":"9.1.1.0.25714478"}}`），
      但 `POST /v1/personalities` 的 `uploadMode` 配套欄位還沒試出來（欄位名 `uploadMode` 已確認正確，
      錯誤訊息會回顯值；缺的是對應的 spec 物件）。UI 路徑應該可行。
- [ ] NSX dataplane 升級（`NSX_T_DATAPLANE` 仍 PENDING）

---

# 附錄：Fleet Manager 對這台「掛在外面的單機」能做什麼（2026-09-09 實測）

## ✅ 能做：監控 / 告警 / 容量（VCF Operations）
esx05 **自動被納入**，因為它在一座被 fleet 管的 vCenter 裡 —— 不需要任何額外動作。

```
GET /suite-api/api/resources?resourceKind=HostSystem
→ 6 台：m01-cl01 的 4 台 + vcd-esx01 + vcf-m02-esx05.home.lab
   狀態 DATA_RECEIVING（叢集內的主機是 4 個 DATA_RECEIVING，esx05 是 3 個 —— 少一個 adapter）

GET /suite-api/api/resources/{id}          → kind=HostSystem, adapterKind=VMWARE
GET /suite-api/api/resources/{id}/statkeys → 217 個 metric key
GET /suite-api/api/alerts?resourceId={id}  → 1 筆
   "Host has lost connection to vCenter Server" [CANCELED]
   ← 就是昨天 vLCM 升級重開機時觸發的，恢復後自動關閉
```
→ **效能、容量、健康、告警、日誌這些 Day-2 監控，fleet 全部照管。**

## ✅ 能做：提供升級素材（Software Depot）
vCenter 的 vLCM online depot 清單裡本來就有 fleet 這一側的來源：
```
"SDDC Manager Unified Depot"  https://vcf-m02-sddcm01.home.lab/vmware/vcf/umds/patch-store/...
"vSphere ESXi patches via VCF Depot"  http://localhost:1080/depot/PROD/COMP/ESX_HOST/main/vmw-depot-index.xml
```
→ 獨立主機升級要用的 base image，走的是 **fleet 的 depot 管道**（我們手動匯入的 9.1.1 zip 也是進同一個 vLCM depot）。

## ❌ 不能做：Lifecycle 版本管理 / 升級
VCF Operations → Build → Lifecycle → VCF Instances → vcf-m02 → **m01** → Component Versions：

| 區塊 | 內容 |
|---|---|
| Domain Management Components | SDDC Manager 9.1.1 **On Target** / VMware NSX 9.1.0 **Version Drift** / VMware vCenter 9.1.1 **On Target** |
| **ESX** | **以 Cluster 為單位**：只有 `m01-cl01`，9.1.0.0200.25557999 → 9.1.1.0.25714478 **Version Drift** |

🔴 **esx05 完全不在這個清單裡** —— fleet lifecycle 的 ESX 管理粒度是 **cluster**，不是 host。

## 🔴 也不能把它納管回 VCF（新發現的擋點）
```
POST /v1/hosts/validations   （esx05 現在是 9.1.1，且已掛在 vCenter 底下）
→ FAILED: "The host vcf-m02-esx05.home.lab is already managed by a vCenter with IP 10.0.1.19
           and therefore cannot be commissioned from SDDC Manager."
```
**這個檢查排在版本檢查之前。** 意思是：
- 一台**已經加進 VCF 的 vCenter** 的獨立主機，**不能再 commission 進 SDDC Manager**
- 要納管就必須**先從 vCenter 移除**，回到「乾淨、無人管」的狀態
- 反過來說，VCF 知道它存在，但明確把它歸類為「不歸我管」

## ❓ 未確認：精靈的 Step 5「Select Standalone Hosts」
Configure Upgrade 精靈（VCF Ops → Lifecycle → m01 → Upgrades → VMware ESX 9.1.1.0 Upgrade → CONFIGURE）有六步：
```
1 Introduction
2 Select Clusters and Hosts with Images      ← 只列出 m01-cl01 (4/4)
3 Assign Images to Clusters
4 Clusters with Images Upgrade Options
5 Select Standalone Hosts                     ← 沒能打開確認
6 Review
```
Introduction 明講：「A batch can contain all hosts from a cluster or a subset of the hosts,
**and also standalone hosts**.」

**沒走到 Step 5 的原因（工具面的坑）**：
🔴 **VCF Operations 9.1.1 的 Local Account 登入會讓 Chrome 152 的 renderer 陷入無窮迴圈**
- 兩個獨立 profile、有頭 / 無頭都 100% 重現
- 症狀：click LOG IN 後 URL 停在 `login.action?vcf=1`，之後 `Page.enable` / `Runtime.evaluate` 全部逾時
- **不是 JS 對話框**：`Page.handleJavaScriptDialog` 回 `No dialog is showing`
- 繞道也不通：VCF SSO → VIDB 只有 **Directory Login（AD）**，沒有 AD 帳密；
  SDDC Manager UI 已 **deprecated**（`/inventory/domains/{id}/update-patches` 直接 404，
  橫幅寫「Please use VCF Operations console to perform all Day-N activities」）

> 依 §「不能納管回 VCF」的證據推測 Step 5 不會列出 esx05，但**這是推論，不是實測**。

## 一句話回答
> **Fleet Manager 對這台單機：「看得到、管得動監控、餵得到升級素材，但升級不歸它管。」**
> 監控自動涵蓋；lifecycle 以 cluster 為單位所以看不到它；連想把它 commission 回 VCF 都被擋
> （已被 vCenter 接管）。升級責任在 vCenter 的 vLCM —— 也就是昨天實測成功的那條路。

---

## ✅ 補完：Step 5「Select Standalone Hosts」實際打開了（2026-09-10）

用 **claude-in-chrome 驅動使用者本機的 Chrome** 登入 VCF Operations（Local Account / admin），
成功走進 Configure Upgrade 精靈。

### 怎麼繞過 Step 3 的死結
精靈 Step 3「Assign Images to Clusters」必定卡住：
```
⚠ There are no images available that match the required target version to initiate the vLCM upgrade.
   → NEXT 灰掉
Assign image 對話框：「Showing only images with ESXi version 9.1.1.0.25714478」→ No images found
```
**繞法**：回 Step 2 選 **Custom Selection**，把 `m01-cl01` 的勾**取消**（0/4）。
一旦沒有選任何叢集，精靈會**自動收掉 Step 3/4**，直接變成
`1 Introduction → 2 Select Clusters and Hosts with Images → 3 Select Standalone Hosts → 4 Review`。

### 🔴 答案
**Select Standalone Hosts** 頁面寫得很清楚：
> "All standalone hosts **in the workload domain** are upgraded by default.
>  You can choose to select the standalone hosts to be upgraded."
>
> **No standalone hosts found**　(0 - 0 of 0 items)

→ **esx05 不在裡面。**
關鍵字是 **in the workload domain**：VCF 這裡講的 standalone host 是
「**已被 VCF 納管（commissioned 進 workload domain）但不屬於任何叢集**的主機」
（典型例子：vSAN stretched cluster 的 witness host）。
esx05 只存在於 vCenter、不在 workload domain 裡，所以 fleet 根本看不到它。

這與先前 API 的證據完全一致：
```
The host vcf-m02-esx05.home.lab is already managed by a vCenter with IP 10.0.1.19
and therefore cannot be commissioned from SDDC Manager.
```
**已經掛在 vCenter 底下 → 不能 commission → 不在 workload domain → fleet lifecycle 管不到。**

### 順帶查清楚的：Image Catalog 到底缺什麼
`GET /api/esx/settings/repository/software`（vCenter 的 vLCM Image Catalog）其實**有** 9.1.1：

| id | 名稱 | base image | editable | orchestrator owner | 指派 |
|---|---|---|---|---|---|
| software-spec-1 | Management-Domain-ESXi-Personality | 9.1.0.0.25370933 | true | **vcf-m02-sddcm01**（`sddcPersonalityId`）| — |
| software-spec-2 | autogen-software-spec-1 | 9.1.0.0200.25557999 | false | 空 | cluster m01-cl01 / m01-cl02 |
| software-spec-4 | autogen-software-spec-2 | **9.1.1.0.25714478** | false | 空 | **host** vcf-m02-esx05 |

`software-spec-4` 就是昨天替 esx05 建 desired image 時自動產生的。
但 VCF 精靈不採用它 —— 只認 **orchestrator owner = SDDC Manager 的 personality**。
想自己補一份也不行：
```
POST /api/esx/settings/repository/software/drafts → 設 base-image + display-name → commit
→ FAILED  ALREADY_EXISTS
   "Image with the input desired state already exists in the Image Library with the name
    'autogen-software-spec-2'. Provide a unique desired state or reuse the existing image."
```
（重複的 desired state 不能重建；要有 personality 只能讓 SDDC Manager 從**叢集**匯入。）

### 瀏覽器操作的坑（記下來省得再踩）
- 🔴 **VCF Ops 的 Configure Upgrade 精靈在 `plugin-iframe` 裡、且內容是 closed shadow DOM**
  —— `querySelector` / a11y tree 全部抓不到按鈕，只能用座標點。
- jumpbox 的 Chrome 頁面縮放很大，viewport 只有 940×471，對話框底部按鈕被裁掉。
  **解法**：把最後一個 `plugin-iframe` 撐高再縮放，整個精靈就進得來：
  ```js
  const p=[...document.querySelectorAll('plugin-iframe')].pop();
  p.style.height='820px'; p.style.transformOrigin='top left'; p.style.transform='scale(0.45)';
  ```
  （CSS transform 不影響點擊命中，座標照著縮放後的畫面點即可；事後把 style 清掉還原。）
- 昨天 CDP Chrome 登入 Ops 會讓 renderer 無窮迴圈，**今天用使用者本機 Chrome（claude-in-chrome）登入正常**
  —— 所以那是 CDP/profile 的問題，不是 Ops 本身壞掉。

---

# 附錄 2：1G NIC 主機能不能 commission？怎麼跳過？（2026-09-14）

esx05 改成 4×e1000e（ESXi 認成 1000 Mb / ne1000）、回滾到 9.1.0.0200 後實測。

| 步驟 | 結果 |
|---|---|
| validation（10G） | ❌ `Host must have minimum two 10Gig NIC(s). Host does not have any 10G Speed NIC(s).` |
| 找程式 | operationsmanager → `libvcf-host-validators.jar` → `HostHardwareValidator`，讀 `${enable.speed.of.physical.nics.validation:true}` |
| 加 `enable.speed.of.physical.nics.validation=false` 到 `/etc/vmware/vcf/operationsmanager/application.properties`，`systemctl restart operationsmanager` | validation 改報下一關（VMs found） |
| 清 VM 後 commission | ✅ Successful，inventory `nics=1000,1000,1000,1000`、UNASSIGNED_USEABLE |

另外撞到：commission 擋 **maintenance mode**；esxcli 拒絕降版 → 用 `bootstate=3` 回滾 altbootbank；
vcf 帳號無 sudo/su 不能用 → root 操作走 vCenter guest-ops。
⚠ 只證明能進 free pool；加入叢集後 vSAN/NSX 在 1G 上跑不跑得動是另一回事，且此開關 Broadcom 不支援。

---

# 附錄 3：1G NIC / 斷線 uplink / 單條 uplink（2026-09-14）

## 1G NIC 主機能不能 commission？可以，但要關掉速度檢查
擋點訊息 `Host must have minimum two 10Gig NIC(s). Host does not have any 10G Speed NIC(s).`
程式在 **operationsmanager** 的 `libvcf-host-validators.jar` → `HostHardwareValidator`，
讀 `${enable.speed.of.physical.nics.validation:true}`。

同一把 property **兩個服務各自讀**，要放對檔案：

| 場景 | 讀取 class | 放哪個檔 |
|---|---|---|
| Installer bring-up 主機驗證 | domainmanager `EsxiHostValidator` | `/etc/vmware/vcf/domainmanager/application.properties` |
| Day-N 建 WLD / 建叢集 / 加主機到叢集 | domainmanager `DomainValidator`、`ValidateClusterCreationSpecAction`、`ClusterController` | 同上（SDDC Manager 上）|
| Day-N commission 進 free pool | operationsmanager `HostHardwareValidator` | `/etc/vmware/vcf/operationsmanager/application.properties` |

```properties
enable.speed.of.physical.nics.validation=false
```
改完 `systemctl restart domainmanager`（或 `operationsmanager`）。
✅ 實測：esx05 換成 4×e1000e（1000 Mb）後 commission Successful、
並且**完整加入 m01-cl01**（vSAN disk group + NSX Transport Node Collection 全過）。

同 class 另有 `enable.vmknic.tags.validation`（vmk0 只准 Management tag）。

## 單條 uplink 的 VDS：9.1 預設就支援
`libvcf-sddcmgr-feature-flags.jar!feature.properties`：
```properties
feature.vcf.VGL-29478.lag-and-single-pnic=true      # 預設就是 true
```
被 `HostHardwareValidator`、`DvsSpecValidator`、`ManagementPortgroupUplinkTeamingValidationAction`、
`AddHostsToDvsAction`、`MigrateHostManagementVmknicsToDvsAction`（有 `isSinglePnicFeatureEnabled` 分支）
共同讀取 → `hostNetworkSpec.vmNics` 只給一條是走得通的設計，不用改參數。

同一份 feature.properties 撈到的其他相關開關：
| flag | 預設 | 意義 |
|---|---|---|
| `feature.vcf.vgl-29121.single.host.domain` | **false** | 單一 ESXi 的 MGMT / VI domain（程式有、關著）|
| `feature.vcf.VGL-36305.standalone.host.lifecycle` | true | 獨立主機升級 / 轉換支援 |
| `feature.vcf.vgl-19927.vsan.two.node.compute.cluster` | true | 2 節點 compute cluster |

## 一條 uplink 沒 link 會擋在哪
用 `govc device.disconnect` 把 esx05 的 vmnic1 斷線實測：

| 關卡 | 沒 link 擋不擋 | 能跳嗎 |
|---|---|---|
| Commission validation | 不擋（只數 Up 的 NIC ≥ 2）| — |
| 加叢集 spec validation | 不擋（只看 vmnic 名稱存不存在）| — |
| `Validate vMotion Network Connectivity` | ❌ `The link status of Network NICs 'vmnic1' ... is down` | ✅ `validation.disable.vmotion.connectivity.check=true` |
| `Validate vSAN Network Connectivity` | ❌ 同一套 | ✅ `validation.disable.vsan.connectivity.check=true` |
| **`Validate Uplink Teaming Policy for Management Port Group`** | 🔴 **擋死** | ❌ **沒有 flag**：`There are no free vmnics available ... to configure the management portgroup for the DVS` |

最後那關是 vSwitch0→VDS 遷移演算法需要一條「沒被 vSwitch0 佔用 + link UP」的 vmnic。
**實務做法**：斷線那條不要寫進 `hostNetworkSpec.vmNics`，改用一條 up 的；
加完再修好線、事後從 vCenter 換 uplink。前兩個 skip flag 也就不需要了。

## 其他實測坑
- commission 也擋 **maintenance mode**（`ESXi host is in maintenance mode.`），排在版本檢查之前。
- **ESXi 9 不能用 esxcli 降版**（`Downgrade ESXi from 9.1.1 to 9.1.0 is not supported`，
  `--allow-downgrades` 也不行）→ 改用 bootbank 回滾：
  `sed -i 's/^bootstate=0/bootstate=3/' /bootbank/boot.cfg` 後重開（等同 Shift+R）。
- 🔴 **bootbank 回滾不會退 /locker 的 tools-light** → 之後加叢集會被 vLCM 判 `INCOMPATIBLE`
  （`VLCM_REMEDIATE_PERSONALITY_FAILED ... 'incompatible' compliance state`）。
  修法：`esxcli software vib remove -n tools-light` 再從對應版本的 zip `vib install -n tools-light`。
- nested 換 1G NIC：要 `govc device.remove ethernet-0..3` 再
  `vm.network.add -net.adapter e1000e` ×4（`vm.network.change -net.adapter` 不會換型別）。
  ESXi 9.1 用 `ne1000` 驅動認 e1000e。
- SDDC Manager 的 `vcf` SSH 帳號 **sudo 只允許 `/opt/vmware/sddc-support/sos`**、`su` 要 tty
  → root 操作一律走外層/nested vCenter guest-ops。
