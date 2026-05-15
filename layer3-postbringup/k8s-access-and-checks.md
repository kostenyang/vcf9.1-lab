# VSP Supervisor / VCF Automation K8s — 登入方式與檢查指令

> M02 三層健康監看用的速查表:怎麼登進各個 K8s、拿到 kubeconfig / sudo,
> 以及 etcd 健康度、控制平面 crashloop、pod 狀態的檢查指令。
>
> 搭配 [vcf-operations-automation-deploy-troubleshooting.md](./vcf-operations-automation-deploy-troubleshooting.md)
> 一起看(那份是故障排除敘事,這份是可重複使用的操作速查)。
> 密碼一律以 `<...>` 佔位符表示,實際值見 `inventory/secrets/`(sops 加密)。

---

## 0. 三層各自登哪裡(總表)

| 層 | 目標 | 登入方式 | 拿權限 |
|----|------|----------|--------|
| 部署狀態 | VCF Installer `10.0.1.4` | SSH `vcf` / `<vcf-pw>` | 跑 `/tmp/sddcstat.sh` 即可;要 root 看 log 才需 pty+su |
| VSP Supervisor K8s | 控制平面節點 `10.0.0.222` | SSH `vmware-system-user` / `<vsp-cp-pw>` | `echo '<pw>' \| sudo -S sh -c '...'` |
| VCF Automation K8s | Automation 節點 `10.0.0.243` | SSH `vmware-system-user` / `<auto-pw>` | `echo '<pw>' \| sudo -S sh -c '...'` |
| 底層實體 | 實體 ESXi `10.0.0.95` | SSH `root` / `<esxi-root-pw>` | 直接 root |

⚠️ 重點限制:
- **VSP Supervisor 控制平面節點 root/SSH 密碼會定期輪替**(vSphere with Tanzu 行為)。
  失效時要從 vCenter 重新取(見 §1.1)。
- **只有控制平面節點**(本 lab `10.0.0.222`)的 `/etc/kubernetes/admin.conf` 可用,
  其他 Supervisor 節點是空的。
- `sudo` 在這兩個 K8s 節點都要用 `echo '<pw>' | sudo -S`(非互動 SSH 沒有 tty,
  直接 `sudo` 會報 `sudo: a terminal is required`)。
- **實體 ESXi** 部分機器只接受 `publickey` / `keyboard-interactive`,無法用密碼登入;
  要查底層挑可密碼登入的那台(本 lab `10.0.0.95`)。

---

## 1. VSP Supervisor K8s(控制平面節點 10.0.0.222)

### 1.1 登入

```bash
ssh vmware-system-user@10.0.0.222          # 密碼 <vsp-cp-pw>
```

密碼若失效(輪替過了),從 M02 vCenter 取回 Supervisor 控制平面密碼:

```bash
# 在 M02 VCSA 上(vCenter 取 root bash 見 §4)
/usr/lib/vmware/wcp/decryptK8Pwd.py
```

`admin.conf` 在 `/etc/kubernetes/admin.conf`(需 sudo 讀)。

### 1.2 etcd 健康度 + 控制平面 crashloop 檢查

整段包成一個 `sudo -S`(非互動)。`<etcd-pw>` = 該節點 sudo 密碼。

```bash
echo '<vsp-cp-pw>' | sudo -S sh -c '
  C=$(crictl ps --name etcd -q | head -1)

  # (a) etcd endpoint 健康
  crictl exec $C etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint health

  # (b) wal_fsync / backend_commit:抓兩次 metrics 算 12 秒平均
  A=$(curl -s http://127.0.0.1:2381/metrics | grep -E \
    "etcd_disk_wal_fsync_duration_seconds_(sum|count) |etcd_disk_backend_commit_duration_seconds_(sum|count) ")
  sleep 12
  B=$(curl -s http://127.0.0.1:2381/metrics | grep -E \
    "etcd_disk_wal_fsync_duration_seconds_(sum|count) |etcd_disk_backend_commit_duration_seconds_(sum|count) ")
  echo "A:"; echo "$A"; echo "B:"; echo "$B"

  # (c) 控制平面 crashloop:看 restart / ATTEMPT 數
  crictl ps -a --name "etcd|kube-apiserver|kube-vip"

  uptime
'
```

**判讀**:
- `avg = Δsum / Δcount`(B 減 A)。**wal_fsync 健康 < 10ms**,> 100ms 即危險。
  本 lab 故障時量到 135ms ~ 4s。
- `crictl ps -a` 的 `ATTEMPT` 欄位就是 restart 次數;持續增加 = crashloop。
- `endpoint health` 要回 `is healthy`。

---

## 2. VCF Automation K8s(Automation 節點 10.0.0.243)

### 2.1 登入

```bash
ssh vmware-system-user@10.0.0.243          # 密碼 <auto-pw>
```

kubeconfig 在 `/etc/kubernetes/admin.conf`(需 sudo)。
VCF Automation app 跑在 **`prelude`** namespace;平台層在 **`vmsp-platform`** namespace。

### 2.2 pod 狀態 / prelude / events 檢查

```bash
echo '<auto-pw>' | sudo -S sh -c '
  K="kubectl --kubeconfig=/etc/kubernetes/admin.conf"

  # (a) 全 namespace pod 狀態統計
  $K get pods -A --no-headers | awk "{print \$4}" | sort | uniq -c

  # (b) 非 Running / 非 Completed 的 pod
  $K get pods -A --no-headers | grep -vE "Running|Completed"

  # (c) prelude namespace 內沒 fully-ready 的 pod(READY 欄 a/b 不相等 或 非 Running)
  $K get pods -n prelude --no-headers | grep -vE "Completed" | \
    awk "{n=split(\$2,a,\"/\"); if(a[1]!=a[2] || \$3!=\"Running\") print}"

  # (d) 最近事件(確認有沒有在動 / 找卡點)
  $K get events -A --sort-by=.lastTimestamp | tail -20

  # (e) namespace 清單
  $K get ns

  uptime
'
```

**判讀**:
- `Init:CreateContainerConfigError` 等 per-service DB 密鑰時 = postgres operator 競態,
  `RESTARTS=0` 的話會自解;超過 2~3 個 cycle 沒解才算問題。
- `prelude` namespace 空 = 平台層(`vmsp-platform`)還沒建完,屬正常順序。
- 真正要警戒的是:新的 `CrashLoopBackOff`、`RESTARTS` 開始累加、大量 `Error` pod。

---

## 3. VCF Installer 部署狀態(10.0.1.4)

### 3.1 一般查詢(vcf 使用者即可)

```bash
ssh vcf@10.0.1.4                           # 密碼 <vcf-pw>
bash /tmp/sddcstat.sh
```

`/tmp/sddcstat.sh` 做的事:`POST https://localhost/v1/tokens`(admin@local / `<installer-admin-pw>`)
取 token → `GET /v1/sddcs/{id}` → 印 `OVERALL STATUS` + subtask 統計 + 非成功 / 最後 6 個 subtask。

### 3.2 要 root 看 domainmanager log(vcf 的 sudo 受限,只能跑 sos)

`vcf` 不能直接 `sudo`,`su -` 又需要 controlling terminal。解法是用 `script` 造一個 pty:

```bash
(sleep 2; echo '<root-pw>') | script -qec "su - root -c '<command>'" /dev/null
```

例:看 Fleet LCM 相關 log

```bash
(sleep 2; echo '<root-pw>') | script -qec "su - root -c '\
  grep -aiE \"fleet|prelude|vcfa|automation\" \
  /var/log/vmware/vcf/domainmanager/domainmanager.log | tail -30'" /dev/null
```

---

## 4. 底層實體 ESXi(10.0.0.95)

```bash
ssh root@10.0.0.95                         # 密碼 <esxi-root-pw>
esxcli vsan debug resync summary get       # Total Bytes Left To Resync 要歸 0
uptime
```

底層實體 vSAN 若還在 resync,會把疊在上面的 nested vSAN 寫入延遲放大,
進而拖垮 VSP Supervisor 的 etcd —— 這是本 lab 部署失敗的根因(見 troubleshooting 紀錄)。

---

## 5. 補充:M02 vCenter 取 root bash

VCSA 的 appliancesh 不能直接跑 bash 指令(會吃掉引號 / pipe)。把 root 的 shell 換成 bash:

```bash
# 在 appliancesh 內
shell chsh -s /bin/bash root
# 用完回復
chsh -s /bin/appliancesh root
```

VCSA 內建 pyVmomi 在 `/usr/lib/vmware/site-packages`(含 `pbm` storage policy 模組):

```bash
PYTHONPATH=/usr/lib/vmware/site-packages python3 <script.py>
```
