# Air-Gap VKS 安裝 Runbook(封閉客戶端可執行)

> 目標:在**完全離線(air-gap)**的 VCF 9.1 環境把 **VKS(vSphere Kubernetes Service)**裝到能開 guest cluster,
> **全程零外部 registry、零 subscribed HTTP server**。
>
> 三段模型:**① 連網側(staging,有網)打包 → ② 搬過氣隙(USB/DVD/單向閘) → ③ 封閉側(target)PUSH 進 vCenter 執行**。
> 兩層:**Layer A = Supervisor 控制面**(photon-ova + spherelet)、**Layer B = TKr guest cluster 節點映像**(TKr OVA)。
>
> 驗證狀態:Layer A 全流程 2026-07-16 於 nested lab **實機驗證通過**;Layer B 為 VMware 標準程序(本 lab 尚未跑完 guest cluster,指令為官方對應)。

---

## 需要跨越氣隙的檔案清單(先在連網側備齊)

> 🟢 **2026-08-20 實機修正:Layer A 根本不用跨氣隙 —— vCenter 出廠自帶。**
> 在 `vcf-m02-vc01`(9.1.0.0100)上驗證:
> ```
> /usr/lib/vmware-wcp/spherelet/vsphere-wcp-depot-embedded.zip   # 完整 offline depot(196MB)
>    └─ vib20/spherelet/VMware_bootbank_spherelet_9.0.1.{30,31,32}*.vib
> /usr/lib/vmware-wcp/spherelet/k8s-1.3{0,1,2}/spherelet-embedded.vib
> /usr/lib/vmware-wcp/wcpagent/photon-ova.ovf + .vmdk + .mf      # Supervisor CP VM 映像
> ```
> 且已自動註冊進 vLCM(offline depot 清單有 system 的 `WCP offline bundle`)並解到
> `/storage/updatemgr/patch-store/hostupdate/vmw/vib20/spherelet/`。
> 本 lab 實跑的 Supervisor = `v1.32.9+vmware.2-fips-vsc9.1.0.0100-25417926`,build 對得上 vCenter 自己 → **就是內建那份**。
> → `VMware-vSphere-Supervisor-*.zip` 只在**要升到比 vCenter 內建更新的版本**時才需要搬
> (本 lab 搬 0200 的實際效果 = `available_versions` 多出 0200 可升)。
> **VKr 沒有內建**,全機 `find` 不到 —— 那是唯一真正必須跨氣隙的檔。

| 檔 | 來源 | 大小 | 用途 |
|---|---|---|---|
| **VKr node OVA**(如 `ob-24945258-photon-5-amd64-v1.32.7---vmware.3-fips-vkr.1`) | **Broadcom 網站 / support portal**(vCenter 不帶) | ~5.7 GiB/版 | Layer B:guest cluster 節點 ✅**唯一必搬** |
| ~~`VMware-vSphere-Supervisor-9.1.0.0200-25573614.zip`~~ | Broadcom depot(token 下載) | 3.84 GiB | Layer A:**僅升級用**,起 Supervisor 不需要 |
| (選)workload container images | 各 upstream / Broadcom | 視需要 | Layer C:私有 Harbor mirror(最小 demo 不需要) |

解壓 zip 後的結構(= 就是要 PUSH 進 Content Library 的內容):
```
supervisor-9.1.0.0200-25573614/   photon-ova.ovf + photon-ova.vmdk(3.9GB) + .mf + .cert + item.json
spherelet-v1.30/                  spherelet-depot-9.0.1.30.5.1-25226287.zip + spherelet-solution-9.0.1.30.5.1-25226287.json
spherelet-v1.31/                  spherelet-depot-9.0.1.31.6.1-25226282.zip + spherelet-solution-9.0.1.31.6.1-25226282.json
spherelet-v1.32/                  spherelet-depot-9.0.1.32.5.0-25510706.zip + spherelet-solution-9.0.1.32.5.0-25510706.json
lib.json / items.json             （subscribed 模式才用;Local PUSH 用不到）
```

> 🔴 **不需要搬** subscribed lib.json 服務、也不需要在封閉側架 HTTP server —— 封閉側一律用 **Local Content Library + `govc library.import`(PUSH)**。

---

## 前置(封閉側 target 必須先就緒)

1. VCF 9.1 已 bring-up、vCenter + 一個可跑 Supervisor 的 cluster。
2. **Supervisor 網路走 VDS + Foundation Load Balancer(不需 NSX)** — 見 `vcf91-vds-flb-supervisor-success` 記憶 / [context.md]。air-gap 尤其推薦:繞開 NSX VPC/TGW 整坨依賴。
3. 自帶時間源(NTP)、DNS、CA —— air-gap 內要能自解 vCenter/Supervisor FQDN、時鐘一致(否則憑證步爆)。
4. 工具:封閉側放一支 **govc**(單一 static binary,跨平台免安裝)。設定:
   ```bash
   export GOVC_URL='https://administrator@vsphere.local:<pw>@<vcenter-fqdn>'
   export GOVC_INSECURE=1          # 或給 -tls-ca-certs
   export MSYS_NO_PATHCONV=1       # 僅 Windows Git-Bash 需要,擋 /lib/item 路徑被改寫
   ```

---

# Layer A — Supervisor 控制面(離線,無 HTTP server)

### ① 連網側:取得 zip
從 Broadcom depot 用 token 下載 **`VMware-vSphere-Supervisor-9.1.0.0200-25573614.zip`**。**照搬整包**過氣隙即可(內含 photon-ova OVF + 3 個 spherelet)。

### ③ 封閉側:解壓 → 建 Local CL → PUSH
```bash
# 解壓
unzip VMware-vSphere-Supervisor-9.1.0.0200-25573614.zip -d supervisor-library
cd supervisor-library

# 建 Local CL(datastore 用封閉側實際名稱;本 lab = m01-cl01-ds-vsan01)
govc library.create -ds m01-cl01-ds-vsan01 supervisor-local

# 🔴 OVF template item 名字**必須** supervisor-<版本>(= supervisor-9.1.0.0200-25573614),
#    不能照檔名叫 photon-ova,否則 Content Distribution 卡片報 malformed Supervisor OVF template name
govc library.import -n "supervisor-9.1.0.0200-25573614" supervisor-local \
     "supervisor-9.1.0.0200-25573614/photon-ova.ovf"

# 3 個 spherelet:depot.zip + solution.json 塞同一 item(名字隨意,實測 spherelet-v1.30/31/32 OK)
for v in 1.30 1.31 1.32; do
  govc library.import -n "spherelet-v$v" supervisor-local "spherelet-v$v"/spherelet-depot-*.zip
  govc library.import "supervisor-local/spherelet-v$v"   "spherelet-v$v"/spherelet-solution-*.json
done

govc library.ls '/supervisor-local/*'
#   /supervisor-local/supervisor-9.1.0.0200-25573614   (type ovf)
#   /supervisor-local/spherelet-v1.30 / v1.31 / v1.32  (type other)
```
> 若已指派後才發現 OVF 名字錯(庫 in-use 刪不掉,報 `NOT_ALLOWED_IN_CURRENT_STATE ... library in use`)→ **免重傳 3.9GB,REST PATCH 改名**:
> ```bash
> SID=$(curl -sk -u "$U:$P" -X POST https://<vc>/api/session | tr -d '"')
> curl -sk -X PATCH "https://<vc>/api/content/library/item/<itemId>" \
>   -H "vmware-api-session-id: $SID" -H 'Content-Type: application/json' \
>   -d '{"name":"supervisor-9.1.0.0200-25573614"}'      # 回 HTTP 204 = OK
> ```

### 指派 + 啟用 Supervisor
- vCenter UI → **Workload Management / Supervisor Management → Content Distribution → ASSIGN → 選 `supervisor-local`**。
  成功後 Recent Tasks 出現 `Update Library` + `Fetch Content ... spherelet-v1.30/31/32` = WCP 認得。
- 跑 **Activate Supervisor 精靈:VDS + Foundation Load Balancer**(完整值見 vds-flb 記憶)→ config_status=RUNNING。

📄 詳細指令與坑:見同資料夾 **`vks-airgap-tkr-upload.md` 附錄 A**。

---

# Layer B — TKr guest cluster 節點映像(離線)

> TKr OVA 已把核心元件容器 image(antrea/coredns/etcd/kube-*)**預載進 containerd**,
> 所以「裸 Ready」最小 guest cluster **只靠本地 CL + OVA 就能起,零外部 registry**。

TKr 來自 VMware 公開 subscribed CL:**`https://wp-content.vmware.com/v2/latest/`**(vcsp v2 格式,**免帳號、純 HTTPS**)。
`lib.json` → `items.json`(126 個 item)列出所有版本;每個 item = **4 檔**(`photon-ova.ovf` + `photon-ova-disk1.vmdk`〔主檔 5–7GB〕+ `.mf` + `.cert`)。

**列出可抓的版本**(2026-07 實查,對 Supervisor 9.1.0.0200 / spherelet 1.30-1.32 用新的 `vkr` 系列):
| item(資料夾名) | k8s | OS | 大小 |
|---|---|---|---|
| `ob-24945258-photon-5-amd64-v1.32.7---vmware.3-fips-vkr.1` | 1.32.7 | photon-5 | 5.72 GB |
| `ob-24941856-photon-5-amd64-v1.31.11---vmware.3-fips-vkr.1` | 1.31.11 | photon-5 | 5.06 GB |
| `ob-24749206-photon-5-amd64-v1.30.11---vmware.1-fips-vkr.2` | 1.30.11 | photon-5 | 5.43 GB |
| (ubuntu-2204 版各多 ~1.5GB) | | | |
> 🔴 相容性以 Supervisor 綁定後 `kubectl get tkr` 的 `COMPATIBLE=True` 為準;photon 比 ubuntu 小,最小 demo 選 photon。

#### 方法 b(推薦,不需 vCenter):直接 HTTP 抓 4 檔
```bash
BASE=https://wp-content.vmware.com/v2/latest
ITEM=ob-24945258-photon-5-amd64-v1.32.7---vmware.3-fips-vkr.1   # ← 換成要的版本
mkdir -p "$ITEM"
# 🔴 一定要 -C - 續傳 + --retry:wp-content/CDN 會「HTTP 200 但檔案截斷」(實測 5.72GB 只下到 4.23GB)
for f in photon-ova.mf photon-ova.ovf photon-ova.cert photon-ova-disk1.vmdk; do
  curl -fSL -C - --retry 8 --retry-delay 3 --retry-all-errors -o "$ITEM/$f" "$BASE/$ITEM/$f"
done
# 🔴 必做:用 .mf 的 SHA256 校驗完整性(HTTP 200 ≠ 完整!)
cd "$ITEM" && sha256sum -c <(awk -F'[()= ]+' '/SHA256/{print $3"  "$2}' photon-ova.mf)
#   Windows 用 PowerShell(別用 Node readFileSync,>2GB 會 ERR_FS_FILE_TOO_LARGE):
#   Get-FileHash photon-ova-disk1.vmdk -Algorithm SHA256   # 比對 .mf
tar czf ../vks-tkr-1.32.7.tgz .          # 校驗過才打包搬過氣隙
```
> 實測本專案:photon v1.32.7 首抓 curl 回 HTTP 200 但只 4.23GB(SHA 不符)→ `curl -C -` 續傳補到 5,717,611,520 bytes → **SHA256 相符**才算完成。

#### 方法 a(有連網 vCenter 時):subscribed CL → sync → export
```bash
govc library.create -sub=$BASE/lib.json -sub-autosync=false tkr-online
govc library.ls /tkr-online/*                             # 找對版 item 全名
govc library.sync   '/tkr-online/ob-24945258-photon-5-amd64-v1.32.7*'
govc library.export '/tkr-online/ob-24945258-photon-5-amd64-v1.32.7*' /data/tkr/
cd /data/tkr && tar czf vks-tkr-1.32.7.tgz ob-24945258-*/
```

### ③ 封閉側:PUSH 進 Local CL
```bash
tar xzf vks-tkr-1.32.7.tgz -C tkr && cd tkr
govc library.create -ds m01-cl01-ds-vsan01 vks-tkr
govc library.import vks-tkr ./photon-ova.ovf     # govc 自動帶 disk1.vmdk;TKr item 名字不限
govc library.ls /vks-tkr/*
```

### 建 Namespace + 綁 CL + 開 cluster
1. vCenter → Workload Management → **建 vSphere Namespace**;指派 **VM Class**(如 best-effort-small)+ **Storage Policy**。
2. Namespace → **綁 `vks-tkr` Content Library**(TKr 來源)。
3. `kubectl get tkr` 應見 `READY=True COMPATIBLE=True`。
4. Apply 最小 cluster(單 CP,零外部 registry 就能 Ready):
   ```yaml
   apiVersion: run.tanzu.vmware.com/v1alpha3
   kind: TanzuKubernetesCluster
   metadata: {name: vks-min, namespace: ns-vks}
   spec:
     topology:
       controlPlane: {replicas: 1, vmClass: best-effort-small, storageClass: <policy>, tkr: {reference: {name: v1.32.7---vmware.3-fips-vkr.1}}}   # 以 kubectl get tkr 實際字串為準
       nodePools: [{name: np-1, replicas: 1, vmClass: best-effort-small, storageClass: <policy>}]
   ```
   `kubectl get tkc,cluster,machine -n ns-vks` → node Ready(antrea 從 OVA cache 拉、不對外)。

📄 詳細:見 **`vks-airgap-tkr-upload.md`**(正文 ①②③④)。

---

# Layer C(選)— 私有 registry,給 workload image

最小 demo **不需要**。要裝 TKG standard package repo(contour/harbor/fluent-bit…)或自訂 workload image 時才做:
- air-gap 內架 **Harbor mirror**;把要的 image 在連網側 `crane/skopeo copy` 打包搬進來 push 上 Harbor。
- cluster spec 加 `additionalTrustedCAs`(Harbor 憑證)+ image repo override 指向內部 Harbor。

---

# Layer D(選)— 接 VCFA 自助消費

Supervisor RUNNING + guest cluster Available 後,於 **VCF Automation → Container Service** 綁 Supervisor,租戶即可自助開 VKS cluster。

---

## Air-Gap 專屬鐵律(踩過的坑)
1. **不用 HTTP server**:封閉側全走 Local CL + `govc library.import`(PUSH)= 用戶端把本機檔 HTTPS PUT 進 vCenter CLS,vCenter 自己收檔存 datastore,沒有中間 server。(對照 subscribed = vCenter 主動 PULL,才要 server。)
2. **Supervisor OVF template item 名字硬性 `supervisor-<版本>`**;spherelet 名字隨意。
3. **govc 是單一 static binary**,跨平台免裝,最適合封閉端;PowerCLI 也行但 vcsp.other/rename 要掉到 `Get-CisService` 拼 updatesession,較囉唆。
4. **Supervisor 走 VDS+FLB 不碰 NSX**,air-gap 依賴最少。
5. 時鐘/DNS/CA 一定要 air-gap 內自足(NTP 指內部源、DNS 自解、CA 匯入)。
6. Git-Bash 跑 govc 要 `export MSYS_NO_PATHCONV=1`。
7. **wp-content 下載會「HTTP 200 假完整」** —— 大檔(TKr vmdk 5–7GB)常靜默截斷。**必用 `curl -C - --retry` 續傳 + `.mf` 的 SHA256 校驗**;Windows 用 `Get-FileHash`(Node `readFileSync` >2GB 會爆)。整庫 >200GB,只抓要的 3+ 版。

## 一句話
連網側 `library.export`+`tar` 打包 → 搬過氣隙 → 封閉側 `govc library.import` PUSH 進 **Local** CL(Supervisor bundle + TKr OVA)→ 綁 Supervisor / Namespace → 開單 CP cluster。**全程零外部 registry、零 HTTP server。**
