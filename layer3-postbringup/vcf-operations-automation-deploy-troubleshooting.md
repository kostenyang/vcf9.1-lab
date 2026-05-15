# VCF Operations / Automation 部署故障排除紀錄 — M02 (2026-05-14)

> VCF 9.1 nested lab,M02 management domain。「Install VCF Operations and VCF Cloud Proxy
> using Fleet Lifecycle」一直失敗,最終定位為 **巢狀 vSAN 儲存效能拖垮 VSP Supervisor
> 控制平面**。本文記錄完整現象 → 調查 → 根因 → 修復 → 除錯指令 → 取得權限技巧。
>
> 密碼一律以 `<...>` 佔位符表示,實際值見 `inventory/secrets/`(sops 加密)。

---

## 1. 問題現象

- VCF Installer 上 `Deploy and configure VCF Operations` milestone 的
  **`Install VCF Operations and VCF Cloud Proxy using Fleet Lifecycle`** subtask 反覆失敗。
- vCenter 端可看到任務狀態 **`The task was canceled by a user`**,以及
  `vmodl.fault.RequestCanceled`。
- 失敗時有一台「VSP machine」被 clone(後來確認是 Fleet LCM 在重試 OVA import)。
- VCF Installer UI 顯示整個 SDDC bring-up 卡在該 subtask,無法往 VCF Automation 推進。

## 2. 調查過程

1. **時間同步** — 比對 installer / SDDC Manager / vCenter / 外部時間,NTP 正常,排除時間問題。
2. **誰在 cancel** — vCenter event 顯示取消任務的帳號是
   `VSPHERE.LOCAL\svc-sddclcm-vc-019e23b5-3ef3-7e39-8b44-9d9ce9af68a4`,
   即 **Fleet LCM 的 service account**。它在 OVA import 超過內部 timeout 後主動呼叫
   `HttpNfcLease.abort()` → vCenter 回 `RequestCanceled`。換言之不是「人」取消,是
   **Fleet LCM 服務自己因 timeout 放棄**。
3. **為什麼 clone VSP machine** — Fleet LCM 服務本身以 pod 形式跑在 VSP Supervisor 的
   `vcf-fleet-lcm` namespace;部署 VCF Operations 時它需要 import OVA,失敗後重試 → 看起來像
   在「clone VSP machine」。
4. **檢查 VSP Supervisor K8s** — 控制平面 `kube-apiserver` / `kube-vip` / `scheduler`
   持續 crashloop(restart 計數一直累加)。
5. **etcd 健康度** — 進到 etcd 容器量 `etcd_disk_wal_fsync_duration` /
   `etcd_disk_backend_commit_duration`,**wal fsync 達 135ms ~ 4s**(健康值應 < 10ms)。
   etcd 寫不動 → apiserver 起不來 → 控制平面 crashloop。
6. **底層儲存** — VSP 的虛擬磁碟落在 nested vSAN,而 nested vSAN 又疊在實體 vSAN 上;
   實體層當時有一輪 vSAN **resync** 正在進行,加上實體是消費級 SATA SSD,IO 已飽和。
   → nested vSAN 寫入延遲爆high → etcd fsync 爆掉。

## 3. 根因(因果鏈)

```
實體消費級 SATA SSD IO 飽和  +  實體 vSAN 正在 resync
        ↓
nested vSAN(疊在實體 vSAN 上)寫入延遲暴增
        ↓
VSP Supervisor 的 etcd:wal fsync 135ms ~ 4s(正常 < 10ms)
        ↓
etcd 寫入逾時 → kube-apiserver / kube-vip / scheduler crashloop
        ↓
VSP Supervisor 控制平面不穩 → 跑在上面的 Fleet LCM 服務無法在內部 timeout 內
完成 VCF Operations 的 OVA import
        ↓
Fleet LCM service account（svc-sddclcm-vc-…）呼叫 HttpNfcLease.abort()
        ↓
vCenter 回 vmodl.fault.RequestCanceled → installer subtask 失敗
```

一句話:**不是 VCF 軟體 bug,是 lab 底層儲存太慢,把 Supervisor 的 etcd 拖垮了。**

## 4. 修復動作

| # | 動作 | 說明 |
|---|------|------|
| 1 | **nested vSAN 儲存原則改 FTT=0** | 用 pyVmomi 的 PBM API 把 M02 nested vSAN storage policy 改成 FTT=0(no mirror),並 **reapply 到全部 M02 VM**,大幅降低 nested 層寫入放大。實體 vSAN 本來就是 FTT=0,**不動實體**。 |
| 2 | **等實體 vSAN resync 跑完** | `esxcli vsan debug resync summary get` 輪詢到 `Total Bytes Left To Resync = 0`,實體 IO 壓力解除。 |
| 3 | **HA admission control 關閉** | nested cluster 資源吃緊,用 pyVmomi 關掉 HA admission control,避免 admission 擋住 VM 開機。 |
| 4 | **domainmanager timeout 參數 ×10** | VCF Installer(10.0.1.4)與 SDDC Manager(10.0.1.18)的 `/etc/vmware/vcf/domainmanager/application.properties` 內所有 timeout 參數 **全部 ×10**(見 `layer2-bringup/timeout-tuning.md`),改完 `systemctl restart domainmanager`。給慢速 lab 足夠的 OVA import / 服務啟動緩衝。 |
| 5 | **VCF Installer UI 按 Retry** | 修復完底層後,**從 VCF Installer UI 手動按 Retry**。注意:domainmanager 重啟後**不會**自動從 Vault 接手續跑,installer retry **必須明確觸發**;UI Retry 會從失敗點續跑、不重做 validation(API 方式則為 `GET /v1/sddcs/{id}/spec` → `PATCH /v1/sddcs/{id}`,但 lab 中 raw PATCH 會撞 `QUICK_START_VALIDATION_FAILED`,IP pool 已被佔用,故走 UI Retry 較穩)。 |

### 修復後驗證

- VSP etcd `wal_fsync` 從 135ms~4s 回到 **5~13ms 健康區間**,控制平面 crashloop 停止。
- installer 續跑後依序完成:VCF Operations(ops01)→ Cloud Proxy(opsc01)→ License Server →
  Telemetry → Identity Broker → Salt Server → Salt Master → **VCF Automation**。
- VCF Automation 應用層(`prelude` namespace)microservice + vksm 服務層全數 Ready。
- 監控期間曾見 etcd fsync 隨 Automation 大量 pod 並發啟動短暫升到 17~27ms,負載回落後即回到
  6~7ms,屬瞬時負載、非回歸。

### 最終結果(2026-05-14 16:36 UTC)

`OVERALL STATUS = COMPLETED_WITH_SUCCESS`,**321 個 subtask 全數成功**,0 失敗。
M02 相關 VM 全 `POWERED_ON`:
`vcf-m02-vc01`、`vcf-m02-sddcm01`、`vcf-m02-nsx01a`、`vcf-m02-vsp01-*`(×4)、
`vcf-m02-ops01`、`vcf-m02-opsc01`、`vcf-m02-license`、`vcf-m02-auto-platform-*`。

---

## 5. 除錯指令清單

### 部署狀態(VCF Installer)
```bash
# /tmp/sddcstat.sh:取 token → GET /v1/sddcs/{id} → 印 OVERALL STATUS + subtask 統計
# token: POST https://localhost/v1/tokens  (admin@local / <installer-admin-pw>)
bash /tmp/sddcstat.sh
```

### VSP Supervisor etcd 健康度
```bash
# 在控制平面節點上(crictl)
C=$(crictl ps --name etcd -q | head -1)
crictl exec $C etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint health

# fsync / backend_commit:抓兩次 metrics 算差值平均(12 秒取樣)
curl -s http://127.0.0.1:2381/metrics | grep -E \
  'etcd_disk_wal_fsync_duration_seconds_(sum|count)|etcd_disk_backend_commit_duration_seconds_(sum|count)'
# avg = Δsum / Δcount;健康 < 10ms,> 100ms 即危險

# 控制平面 crashloop 看 restart 次數
crictl ps -a --name "etcd|kube-apiserver|kube-vip"
```

### Automation / VSP K8s pod 狀態
```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n prelude          # VCF Automation app 層
kubectl --kubeconfig=/etc/kubernetes/admin.conf get events -A --sort-by=.lastTimestamp | tail -20
```

### 底層 vSAN resync
```bash
esxcli vsan debug resync summary get      # Total Bytes Left To Resync 要歸 0
```

### Fleet LCM / domainmanager log(installer)
```bash
F=/var/log/vmware/vcf/domainmanager/domainmanager.log
grep -aiE 'fleet|prelude|vcfa|automation' $F | tail -30
# 找 GetVcfAutomationVmNames / UpdateFirewallExclusionListAction /
#    UpdateVcfAutomationSuccessAction / svc-sddclcm-vc / HttpNfcLease
```

### vCenter 端任務 / cancel 來源
```python
# VCSA 內建 pyVmomi:PYTHONPATH=/usr/lib/vmware/site-packages python3 ...
# 查 recentTask / eventManager,確認 cancel 的 principal 是 svc-sddclcm-vc-… service account
```

---

## 6. 用到的 script

| Script | 位置 | 功能 |
|--------|------|------|
| `/tmp/sddcstat.sh` | installer 10.0.1.4 | 取 token、GET sddc、印 OVERALL STATUS + subtask 統計 + 非成功/最後 6 個 subtask |
| `/tmp/mon.sh` | installer 10.0.1.4 | grep domainmanager.log 的 Fleet LCM task 狀態(grep 要收斂,否則會撈到巨大 JSON 行) |
| pyVmomi HA script | M02 vCenter(暫存,已刪) | 關閉 cluster HA admission control |
| pyVmomi PBM script | M02 vCenter(暫存,已刪) | 改 nested vSAN storage policy 為 FTT=0,並 reapply 到全部 M02 VM(`vim.vm.device.VirtualDeviceSpec`,非 `VirtualDeviceConfigSpec`) |
| `vcf_x10.sh` | installer + SDDC Manager(暫存,已刪) | sed 把 6 個 domainmanager timeout 參數 ×10,重啟 domainmanager |

---

## 7. 如何取得權限(access techniques)

lab 各元件登入限制不同,以下是實際打通的方法:

### VCF Installer / SDDC Manager appliance
- root **不可** 直接 SSH;`vcf` 帳號可 SSH,但 `sudo` 只允許 `/opt/vmware/sddc-support/sos`。
- `su -` 需要 controlling terminal,非互動 SSH 會報 `su: must be run from a terminal`。
- **解法**:`vcf` 登入後用 `script` 建 pseudo-tty 跑 `su - root`,延遲 2 秒餵 root 密碼:
  ```bash
  (sleep 2; echo '<root-pw>') | script -qec "su - root -c '<command>'" /dev/null
  ```

### vCenter (VCSA)
- appliancesh 不能直接跑 bash 指令、會吃掉引號/pipe。
- **解法**:`shell chsh -s /bin/bash root` 把 root 預設 shell 換成 bash;回復用
  `chsh -s /bin/appliancesh root`。
- VCSA **內建 pyVmomi** 在 `/usr/lib/vmware/site-packages`(含 `pbm` storage policy 模組):
  `PYTHONPATH=/usr/lib/vmware/site-packages python3 ...`

### VSP Supervisor 控制平面節點
- SSH 帳號 `vmware-system-user`,登入後 `sudo` 需用 `echo '<pw>' | sudo -S sh -c '...'`
  (非互動,無 tty)。
- 只有**控制平面節點**(本 lab 為 `10.0.0.222`)的 `/etc/kubernetes/admin.conf` 可用,
  其他節點是空的。
- ⚠️ VSP Supervisor 控制節點的 root/SSH 密碼**會定期輪替**(vSphere with Tanzu 行為);
  密碼失效時需從 vCenter 重新取得(`/usr/lib/vmware/wcp/decryptK8Pwd.py`)。

### VCF Automation 節點
- SSH 帳號 `vmware-system-user`,`sudo` 同樣 `echo '<pw>' | sudo -S`。
- kubeconfig 在 `/etc/kubernetes/admin.conf`;VCF Automation app 跑在 `prelude` namespace,
  平台層在 `vmsp-platform` namespace。

### 實體 ESXi
- 只接受 `publickey` / `keyboard-interactive`,**無法用密碼登入**(MCP 工具的密碼登入會失敗)。
- 需要查底層時改從可密碼登入的實體 ESXi(本 lab `10.0.0.95`)跑 `esxcli`。

### VCF Installer retry
- domainmanager 重啟**不會**自動續跑失敗的 task,retry **必須明確觸發**。
- API 方式:`GET /v1/sddcs/{id}/spec` → `PATCH /v1/sddcs/{id}`(帶回 spec body,Broadcom KB 424770);
  但本 lab raw PATCH 撞 `QUICK_START_VALIDATION_FAILED`(IP pool 已被佔用),最後改用
  **VCF Installer UI 的 Retry** 從失敗點續跑。

---

## 8. 教訓 / 後續

- **nested-on-nested vSAN 是效能地雷**:任何實體層 IO 事件(resync、scrub、消費級 SSD 掉速)
  都會被放大成 Supervisor etcd 的致命延遲。lab 環境 nested vSAN 一律 FTT=0。
- **Fleet LCM 的 `RequestCanceled` 不是「使用者取消」**:看到這個錯先去查 Supervisor etcd /
  控制平面健康度,而不是去查「誰按了取消」。
- **慢速 lab 一定要先調 domainmanager timeout**(見 `layer2-bringup/timeout-tuning.md`),
  否則 OVA import / 服務啟動很容易撞內部 timeout。
- 監控腳本的 grep 要收斂範圍,domainmanager.log 有單行數十 KB 的 JSON,寬鬆 grep 會炸輸出。
