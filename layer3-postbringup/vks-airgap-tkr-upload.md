# VKS air-gap TKr — 打包 → 搬進 air-gap → 上傳 Content Library

> air-gap 環境起**最小 VKS** 唯一必須的離線檔 = **一顆對版 TKr node OVA**。
> TKr OVA 已把核心元件容器 image(antrea/coredns/etcd/kube-*)預載進 containerd,
> 所以「裸 Ready」的最小 guest cluster **只靠本地 Content Library + OVA 就能起,零外部 registry**。
> (只有要裝 TKG standard package repo 的額外 add-on 才需要私有 Harbor mirror — 最小 demo 不用。)
>
> 本 lab 值:download tool `vcf9dltool 10.0.0.68` / offline depot `vcf9depot 10.0.0.61` /
> 內層 vCenter(Supervisor 所在)`vcf-m02-vc01.home.lab` = 10.0.1.19 / vSAN `datastore-15`。
> TKr 版本上限 = **k8s-v1.30.1**(Supervisor TKG service 支援上限)。

整條鏈路三段:**① download tool 打包 → ② 搬進 air-gap → ③ 上傳進 vCenter Content Library**。

---

## ① 在 download tool(vcf9dltool 10.0.0.68,對外)取得 + 打包

TKr 訂閱點:`https://wp-content.vmware.com/v2/latest/lib.json`(vSphere subscribed CL 格式:
每個 item = `.ovf + .vmdk + .mf`)。最省事:對外側建 subscribed CL 只同步要的那顆,再匯出。

```bash
# 對外側任何能連網的 vC 建 subscribed CL 指向 wp-content
govc library.create -sub=https://wp-content.vmware.com/v2/latest/lib.json -sub-autosync=false tkr-online
govc library.ls /tkr-online/*                       # 找 v1.30.1---vmware.1 那顆
govc library.sync /tkr-online/photon-ova-v1.30.1*   # 只同步這一顆
govc library.export /tkr-online/photon-ova-v1.30.1* /data/tkr/   # 匯出成本機檔案
```

**打包成一包**(item 是 ovf+vmdk 多檔 → tar 成一包好搬;若已是單一 `.ova` 就跳過,ova 本身就是一包):
```bash
cd /data/tkr && tar czf vks-tkr-v1.30.1.tgz photon-ova-v1.30.1*/
ls -lh vks-tkr-v1.30.1.tgz
```

---

## ② 搬進 air-gap(pscp/scp 到 depot 10.0.0.61 或 jumpbox)

```bash
pscp -pw '<DEPOT_ROOT_PW>' /data/tkr/vks-tkr-v1.30.1.tgz root@10.0.0.61:/data/tkr/
ssh root@10.0.0.61 'cd /data/tkr && tar xzf vks-tkr-v1.30.1.tgz'
```
> ⚠ depot root 密碼是敏感值 — 指令貼對話 OK,**別 commit 進 public repo**(先遮再推)。

---

## ③ 上傳進 vCenter Content Library(Supervisor 認得的「上傳」)

目標 = Supervisor 所在的**內層 vCenter `vcf-m02-vc01`**。設 govc env → 建 **Local** CL → import。

```bash
export GOVC_URL='https://administrator@vsphere.local:VMware1!VMware1!@vcf-m02-vc01.home.lab'
export GOVC_INSECURE=1

# 建 Local content library(要指定 datastore = 內層 vSAN)
govc library.create -ds datastore-15 vks-tkr

# 上傳 OVA/OVF 進 CL
govc library.import vks-tkr /data/tkr/photon-ova-v1.30.1*/photon-ova-v1.30.1*.ovf
#   單檔 ova 版:govc library.import vks-tkr /data/tkr/photon-ova-v1.30.1---vmware.1.ova

# 驗證
govc library.ls /vks-tkr/*
```

上傳完 → **Supervisor Management → 綁這個 CL** → `kubectl get tkr` 應看到 `READY=True COMPATIBLE=True`。

---

## ④ 綁 CL 後起最小 cluster(驗收)

```yaml
apiVersion: run.tanzu.vmware.com/v1alpha3
kind: TanzuKubernetesCluster
metadata:
  name: vks-min
  namespace: ns-vks
spec:
  topology:
    controlPlane:
      replicas: 1                     # 最小:單 CP
      vmClass: best-effort-small
      storageClass: vsan-default-storage-policy
      tkr:
        reference:
          name: v1.30.1---vmware.1    # 用 kubectl get tkr 確認確切字串
    nodePools:
    - name: np-1
      replicas: 1                     # 最小:單 worker(要更小可整段省略,只留 CP)
      vmClass: best-effort-small
      storageClass: vsan-default-storage-policy
```
```bash
kubectl apply -f vks-min.yaml
kubectl get tkc,cluster,machine -n ns-vks       # nodes Ready、antrea 從 OVA cache 拉、不對外
```

---

## 一句話流程
`library.export` + `tar` 成一包 → `pscp` 搬進 air-gap → `govc library.import` 上傳進內層 vCenter Local CL → 綁 Supervisor → apply 單 CP cluster。**全程零外部 registry。**

## 何時才需要私有 registry(B 塊,最小不用)
要裝 TKG standard package repo(contour/harbor/fluent-bit…)或自訂 workload image 時,
才架 Harbor mirror + cluster spec 加 `additionalTrustedCAs` + image repo override。

---

# 附錄 A:Supervisor 映像庫(photon-ova + spherelet)無 HTTP server 離線裝(2026-07-16 實測證實)

> 上面講的是 **TKr(guest cluster node OVA)**。這節是**另一個東西**:**Supervisor images bundle**
> = `VMware-vSphere-Supervisor-9.1.0.0200-25573614.zip`(4.1GB),內含 **1 顆 photon-ova(OVF)+ 3 個 spherelet(v1.30/31/32)**,
> 用途 = **Supervisor 本體啟用/升級的映像源**(Content Distribution → Supervisor Images Library),不是 guest cluster 用。

## 兩種上傳模式(擇一,結論:不用 HTTP server 也能裝)
| | Subscribed(PULL) | **Local + govc import(PUSH)** |
|---|---|---|
| 誰發動 | vCenter 主動去讀 lib.json/items.json HTTP GET 拉檔 | **govc 把本機檔 HTTPS PUT 直接灌進 vCenter CLS** |
| 要不要 HTTP server | **要**(一台 serve.mjs 掛 zip 解壓目錄) | **完全不用** |
| Assign 對話框認不認 | 認 | **認**(Local/Subscribed 都列在「Assign Content Library」清單,實測兩個都可選可 ASSIGN) |

## 無 server 完整步驟(實測 OK)
```bash
export MSYS_NO_PATHCONV=1          # 🔴 Git-Bash 必加,否則 /lib/item 路徑被 MSYS 轉成 C:/Program Files/Git/...
export GOVC_URL='https://administrator@vsphere.local:VMware1!VMware1!@10.0.1.19'
export GOVC_INSECURE=1
# 解壓 zip 後(得 supervisor-9.1.0.0200-25573614/ + spherelet-v1.30/31/32/)
govc library.create -ds m01-cl01-ds-vsan01 supervisor-local          # 建 Local CL
# spherelet ×3:每個 = depot.zip + solution.json 塞同一 item(名字隨意,實測 spherelet-v1.30/31/32 OK)
for v in 1.30 1.31 1.32; do
  govc library.import -n "spherelet-v$v" supervisor-local "spherelet-v$v/spherelet-depot-*.zip"
  govc library.import         "supervisor-local/spherelet-v$v" "spherelet-v$v/spherelet-solution-*.json"
done
# 🔴 photon-ova(OVF)item 名字**必須**是 supervisor-<版本>,不能照檔名叫 photon-ova
govc library.import -n "supervisor-9.1.0.0200-25573614" supervisor-local "supervisor-9.1.0.0200-25573614/photon-ova.ovf"
```
→ vCenter UI **Supervisor Management → Content Distribution → ASSIGN** → 選 `supervisor-local` → ASSIGN。
成功後卡片顯示「Assigned Library Name: supervisor-local」+ Recent Tasks 出現 `Update Library` / `Fetch Content of a Library Item spherelet-v1.30/31/32` 全 Completed。

## 🔴 唯一真陷阱:Supervisor OVF template 命名鐵律
手動 import 若把 OVF item 照檔名命名(`-n photon-ova`),ASSIGN 會成功但 Content Distribution 卡片報:
> `malformed Supervisor OVF template name 'photon-ova'. The template name must be in the format 'supervisor-<supervisor version>'. Example: supervisor-9.1.0.0-25004320.`

- 根因:subscribed 版 item.json 的 `name` 本來就是 `supervisor-9.1.0.0200-25573614`,PULL 自帶正確名;手動 PUSH 要自己給對。
- **spherelet 三個名字隨意**(vcsp.other 不檢查),**只有 OVF template 這一個**有命名檢查。
- 已指派(庫 in-use)時 item **刪不掉**(`NOT_ALLOWED_IN_CURRENT_STATE ... library in use`)→ **免重傳 3.9GB,直接 REST PATCH 改名**:
  ```bash
  SID=$(curl -sk -u "$U:$P" -X POST https://$VC/api/session | tr -d '"')
  curl -sk -X PATCH "https://$VC/api/content/library/item/<itemId>" \
    -H "vmware-api-session-id: $SID" -H 'Content-Type: application/json' \
    -d '{"name":"supervisor-9.1.0.0200-25573614"}'      # 回 HTTP 204 = OK
  ```
  改完刷新 Content Distribution → 錯誤消失、按鈕從 ASSIGN 變 **EDIT** = 健康。

## 機制一句話
subscribed=「vCenter 去別人家搬(要 server 站著)」;local import=「govc 直接搬進 vCenter(vCenter 自己收檔,零 server)」。
兩者對 Supervisor 一樣有效,差別只在 OVF item 名字要自己給對 `supervisor-<版本>`。
