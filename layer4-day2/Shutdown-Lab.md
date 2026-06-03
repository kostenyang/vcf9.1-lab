# Lab 完整關機 / 開機 SOP

> 計畫性把整個 lab(M02 VCF stack + 外層基礎建設)有序關掉,以及對應反序開機。
> 用 KB 440874 腳本只處理 VSP Supervisor / VCF Services Runtime 那一層,其他層
> 必須手動或透過 vCenter 處理 —— 這份是把所有 phase 排好順序的 SOP。

## 何時用

- 計畫性機房維運 / 斷電
- 冷備份 / VM snapshot 整批
- 搬遷 / 退役
- **不適用**:單一元件重啟、暫時 maintenance(那是其他流程)

⚠️ **整個 lab 關下去後外部進不來,執行前確認自己也能進得來重開**(實體 console / iLO / 同網段跳板)。

---

## TL;DR(順序速查)

| 順序 | 關 | 對應開機(反序) |
|---|---|---|
| 0 | 通知 / 凍結 workflow | (最後)恢復排程 |
| 1 | VCFA tenant workloads(終端使用者層) | (最後)VCFA 應用上線 |
| 2 | **VCF Services Runtime**(`vcf_services_runtime_shutdown.sh`,KB 440874)| Supervisor 自動 recovery(power-off-marker)|
| 3 | VCF Operations / Fleet / Collector / License / Salt appliance | appliance 開機 |
| 4 | NSX Manager / Edge | NSX 起來 |
| 5 | SDDC Manager | SDDC Mgr 起來 |
| 6 | VCF Installer | VCF Installer 起來 |
| 7 | M02 vCenter(vcf-m02-vc01) | M02 vCenter 起來 |
| 8 | Nested ESXi(vcf-m02-esx01~04)| Nested ESXi 起來 |
| 9 | 外層 vCenter(labvc / 10.0.0.101)+ 實體 ESXi(*選擇性*)| (最先)實體 ESXi → 外層 vCenter |
| 10 | DNS / 跳板機(*選擇性,務必最後關*)| (最先)DNS / 跳板機 |

---

## Phase 0 — 動工前

```bash
# 1. 通知所有依賴 VCF / VCFA / VCF Ops 的系統與使用者
# 2. SDDC Manager 確認沒有失敗 / 進行中的 workflow
#    (API auth OK 的話可以用 sddc_manager_api 看 /v1/tasks)
# 3. 確認沒有任何 VM 上有開啟的 snapshot(VSP Supervisor 節點 VM 必確認)
# 4. 確認自己進得來機房 / 跳板機
# 5. 開一個工作 log:
script -q /tmp/lab-shutdown-$(date +%Y%m%d-%H%M%S).log
```

---

## Phase 1 — Tenant workloads(VCFA / 應用層)

VCF Automation 上跑著任何 tenant VM / blueprint / pipeline → 通知 tenant 先停。
VCFA 應用層的 pod(`prelude` / `vmsp-platform` namespace)會在 Phase 2 由
VCFMS shutdown 腳本一起處理,**不要**手動 `kubectl drain` 那兩個 namespace。

---

## Phase 2 — VCF Services Runtime(VSP Supervisor + VCFMS)

**用 KB 440874 的腳本**,跑在任何能連 VSP 控制節點 port 5480 的機器。腳本本體在
private repo:[github.com/kostenyang/vcf9.1-lab-private](https://github.com/kostenyang/vcf9.1-lab-private)
(Broadcom Confidential,不在這份公開 repo)。

```bash
# (a) 先 dry-run 確認計畫
./vcf_services_runtime_shutdown.sh \
  --node-ip 10.0.0.222 \
  --dry-run

# (b) 完整關機(服務 + VM)
export VCENTER_USERNAME=administrator@vsphere.local
export VCENTER_PASSWORD='<m02-vcsa-sso-pw>'
./vcf_services_runtime_shutdown.sh \
  --node-ip 10.0.0.222 \
  2>&1 | tee /tmp/vcfms-shutdown-$(date +%Y%m%d-%H%M%S).log
```

腳本會自動:
- 設 power-off-marker(下次開機自動 recovery)
- 內部 dependency ordering
- 透過 `govc` 把 Supervisor VM(`vcf-m02-vsp01-*`)+ VCFA appliance
  (`vcf-m02-auto-platform-*`)都 power off

完整 flag/env var 表 + API 細節見 private repo 的 README。

> **本 lab M02 控制節點 IP**:`10.0.0.222`。`vmware-system-user` 的 breakglass
> 密碼會輪替,失效時走 M02 vCenter 的 `/usr/lib/vmware/wcp/decryptK8Pwd.py`。

---

## Phase 3 — VCF Operations / Fleet / Collector / License / Salt

這幾台是 M02 management 的 appliance,沒被 KB 440874 涵蓋。從外層 vCenter UI(或
`govc vm.power -off`)**Guest OS Shutdown**(不要直接 power off):

| VM 名稱 | IP | 角色 |
|---|---|---|
| vcf-m02-ops01 | 10.0.1.22 | VCF Operations(vROps)|
| vcf-m02-fleet01 | 10.0.1.23 | Fleet Management |
| vcf-m02-opsc01 | 10.0.1.24 | VCF Operations Collector(Cloud Proxy)|
| vcf-m02-license | — | License Server |
| vcf-m02-salt-* | — | Salt Master / Server |
| vcf-m02-idb-* | — | Identity Broker |
| vcf-m02-telemetry-* | — | Telemetry |

```bash
# 從外層 vCenter 一台一台 Guest Shutdown
govc vm.power -s vcf-m02-ops01
govc vm.power -s vcf-m02-opsc01
govc vm.power -s vcf-m02-license
# ...其他依此類推
# 等所有 powerState=poweredOff 再下一個 phase
govc find . -type m -name 'vcf-m02-*' -runtime.powerState poweredOn
```

---

## Phase 4 — NSX Manager / Edge

```bash
# Edge 先(避免 Manager 關掉後 Edge 失去 control plane 重連)
govc vm.power -s vcf-m02-edge-*
# Manager(本 lab single node)
govc vm.power -s vcf-m02-nsx01a
```

---

## Phase 5 — SDDC Manager

`vcf-m02-sddcm01`(10.0.1.18)。Guest OS Shutdown:

```bash
govc vm.power -s vcf-m02-sddcm01
```

---

## Phase 6 — VCF Installer

`vcf-m02-inst01`(10.0.1.4)Bring-up 後是長期 stand-by,可直接 Guest OS Shutdown:

```bash
govc vm.power -s vcf-m02-inst01
```

---

## Phase 7 — M02 vCenter

`vcf-m02-vc01`(10.0.1.19)。**M02 vCenter 關了之後,M02 內所有 govc / API 操作都失效**,
所以這一步前再確認 phase 3–6 都收尾。

```bash
# 從外層 vCenter 對 M02 vCenter VM 下 guest shutdown
govc vm.power -s vcf-m02-vc01
```

---

## Phase 8 — Nested ESXi(M02)

4 台 nested ESXi(`vcf-m02-esx01~04`,10.0.1.14–17)。先進 maintenance 再關機:

```powershell
# PowerCLI 對 4 台 nested ESXi
$hosts = '10.0.1.14','10.0.1.15','10.0.1.16','10.0.1.17'
foreach ($h in $hosts) {
    Set-VMHost -VMHost $h -State Maintenance -Evacuate:$false -RunAsync
}
# 等到全部 ConnectionState=NotResponding/Maintenance,再從外層 vCenter 把
# VM(nested ESXi 本身就是 VM)guest shutdown:
foreach ($n in 'vcf-m02-esx01','vcf-m02-esx02','vcf-m02-esx03','vcf-m02-esx04') {
    Stop-VMGuest -VM $n -Confirm:$false
}
```

---

## Phase 9 — 外層 vCenter + 實體 ESXi(選擇性)

只有要整體斷電 / 機房維運才動。**動之前確認:**
- 自己有跳板機 / DNS 還活著(不然待會兒重開機沒 DNS 解析)
- 實體 ESXi 沒掛其他 lab 在跑(本 lab 共用實體 vCenter 的話特別小心)

```bash
# 1. 外層 vCenter(labvc / 10.0.0.101)Guest Shutdown
#    用 vCenter UI / appliance VAMI(https://labvc:5480)
# 2. 實體 ESXi(10.0.0.95 等)進 maintenance + shutdown
ssh root@10.0.0.95
esxcli system maintenanceMode set --enable true
esxcli system shutdown poweroff --reason "planned lab shutdown"
```

---

## Phase 10 — DNS / 跳板機(務必最後)

DNS(10.0.0.200)、automation host(10.0.0.65)、Open WebUI(10.0.0.64)、
MCP server、跳板機等 —— 這些是讓你「下一輪能進得來」的工具,務必最後關。

---

## 開機順序(反序、概念)

依賴方向反過來:DNS / 跳板 → 實體 ESXi → 外層 vCenter → M02 nested ESXi →
M02 vCenter → VCF Installer → SDDC Manager → NSX → VCF Ops/Fleet/Collector → 
VSP Supervisor + VCFA(腳本設的 power-off-marker 會觸發自動 recovery,
**但 KB 440874 沒明寫詳細 power-on 步驟**,等實測過再回頭補本節)。

開機後驗證(每層各跑一次):
- 實體層:`esxcli vsan debug resync summary get` resync = 0
- nested ESXi:全 `Connected`、no APD/PDL
- VCF API:`bash /tmp/sddcstat.sh` `OVERALL STATUS` 正常
- VSP K8s:`crictl ps -a` etcd/apiserver restart 沒有暴漲、wal_fsync < 10ms
- VCFA:`kubectl -n prelude get pods` 全 Ready

K8s 健康度檢查指令在 [../layer3-postbringup/k8s-access-and-checks.md](../layer3-postbringup/k8s-access-and-checks.md)。

---

## 緊急中止 / 部分關機

| 情境 | 動作 |
|---|---|
| 只關 VCF Services Runtime,其他不動 | 跑 Phase 2 即可 |
| 只關 nested,外層保留 | Phase 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8,停 |
| Phase 中途任一個 task FAILED | **不要繼續**,解決根因(看當下 phase 的 log + KB)再續跑;貿然強制下個 phase 容易資料壞掉 |
| 已關到一半但發現要回退 | 從目前 phase 反序開機回去(風險:VCF Services Runtime power-off-marker 設了之後,recovery flow 沒走完不能正常服務)|

## 注意事項

- 任何 Guest OS Shutdown 不行就退而求其次 `govc vm.power -off`(force),但 SDDC Mgr / vCenter / NSX 那幾台 force 一定要避免(會弄壞 inventory / DB)
- VSP Supervisor 與 VCFA 上的 etcd 需要乾淨關機 —— **這就是 KB 440874 腳本存在的理由**,別跳過直接 Phase 7
- 開機後第一波 etcd fsync 會偏高,等個 10 ~ 15 分鐘觀察,不要急著做事(本 lab 5/14 有實測,見 [../layer3-postbringup/vcf-operations-automation-deploy-troubleshooting.md](../layer3-postbringup/vcf-operations-automation-deploy-troubleshooting.md))
- DNS / NTP 在外層;外層先掛掉內層整批爆炸

## 相關文件

- [Safe-Shutdown-VCF-Services-Runtime.md](./Safe-Shutdown-VCF-Services-Runtime.md) — Phase 2 用到的 KB 440874 runbook
- [../layer3-postbringup/k8s-access-and-checks.md](../layer3-postbringup/k8s-access-and-checks.md) — Supervisor / VCFA K8s 登入與健康度檢查
- [../layer2-bringup/timeout-tuning.md](../layer2-bringup/timeout-tuning.md) — domainmanager timeout 參數(影響開機後服務上線時間)
- private:`vcf9.1-lab-private/README.md` — Phase 2 腳本內部細節(API endpoint / env var 表)
