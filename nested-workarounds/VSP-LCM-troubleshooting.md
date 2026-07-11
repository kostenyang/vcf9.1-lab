# VSP / LCM 卡關完整除錯紀錄(nested VCF 9.1)

bring-up 後段(VCF Management Platform / VSP Supervisor → Deploy Lifecycle Components)在 nested
vSAN 上最容易卡。本文記錄實戰走過的每一關與解法,順 bring-up 流程排。
基礎修法另見 rtolab `timeout-tuning.md` / `nested-bringup-fixes.md`;本文補上 LCM 階段的新發現。

## 症狀分層(依 bring-up 進度)
| done(約) | 階段 | 典型卡點 |
|---|---|---|
| ~268 | Deploy and configure VCF Management Platform / **Monitor VCF Management Services Deployment Task** | VSP Supervisor bootstrap 卡(etcd 慢)|
| ~279-281 | **Deploy Lifecycle Components** | LCM 元件安裝 timeout / 或 No route to host |

---

## 1. VSP bootstrap 卡住(done 卡在 ~268,VSP VM create/delete 迴圈)
**根因**:nested-on-nested vSAN 的 etcd fsync 3-4 秒(`crictl logs etcd` 看到 "took too long" 3.8s、"waiting for ReadIndex")→ Supervisor 永遠穩不下 → VCF 重試重建。

**解法(全套一起上)**:
1. `Disable-HaAdmissionControl.ps1` — 否則 VSP appliance 放不下去
2. `Set-VsanFtt0.ps1 -ReapplyExisting` — FTT=1 雙寫拖垮 etcd,改 FTT=0
3. `Set-NestedReservations.ps1` — 防外層 swap nested ESXi(etcd I/O 經 swap 會災難級慢)
4. 降低 outer vSAN I/O 競爭(關非必要 VM)
5. **清掉重建中的 VSP 殘骸 + PATCH retry** → 每次推進一段(實測 268→270→281)

## 2. ⚠️ VSP 到 done≈281(VSP cluster 完成)後 **絕對不能刪 VSP VM**
**血淚**:281 之前卡 bootstrap,「刪 VSP + retry」會推進;但**一旦 281,LCM 步驟需要活的 VSP**。
刪掉 → `PUBLIC_LCM_COMPONENTS_DEPLOY_FAILED / java.net.NoRouteToHostException`(連不到被刪的 Supervisor),
而且 task 不會重建已標記完成的 VSP → 卡死,只能整個重跑。**281 後 retry 一律保留 VSP。**

## 3. LCM 元件安裝 timeout(`PUBLIC_SDDC_LCM_COMPONENT_DEPLOY_FAILED`)
**錯誤**:`Installing VSP component vcf-sddc-lcm ... Retriable operation 'Waiting for VSP task' failed after 60 retries, task pending/queued`
**根因**:etcd 慢 → VSP 元件安裝任務久久不完成 → domainmanager **預設 timeout/重試上限太低**就放棄。
**解法 = 把 timeout 延長套到「這次新部出來的」SDDC Manager(10.0.1.18)**(不只 installer 10.0.1.4!):
`/etc/vmware/vcf/domainmanager/application.properties` 加:
```
vsp.bootstrap.task.timeout.minutes=240
vsp.bootstrap.command.timeout.minutes=200
vc.appliance.services.check.timeout.minutes=240
orchestrator.task.retry.max=240
nsxt.manager.wait.minutes=180
edge.node.vm.creation.max.wait.minutes=90
```
然後 `systemctl restart domainmanager`。

### 取 root 的方法(SDDC Manager / installer)
- root 不能直接 SSH;`vcf` 可登入但非完整 sudoer。
- **Posh-SSH 對 Photon 的 KEX 常 "Key exchange negotiation failed" → 改用 `plink`(PuTTY)**。
- root 需 pty:
```
(sleep 2; echo '<rootpw>') | script -qec "su - root -c '<cmd>'" /dev/null
```
- SDDC Manager / installer root 密碼 = `VMware1!VMware1!`(本 lab)。

## 4. retry 死結:VSP 活著 → `QUICK_START_VALIDATION_FAILED IPv4 pool in-use`
**狀況**:281 後要 retry LCM,但 VSP 活著佔住 pool IP(10.0.0.220-225),retry 被擋,
`skipValidations=true` 也擋不掉。刪 VSP 又會觸發 #2 的 No route。
**解法 = 把 spec 的 `vspClusterSpec.ipv4Pool` 起點移到 VSP 佔用範圍之上**(例:`220`→`226`),
驗證就不會抓到衝突,retry 通過,VSP 保持活著、LCM 沿用它。

---

## LCM 卡關「正確」復原順序(VSP 已到 281)
1. **不要刪 VSP**(#2)
2. 套 timeout 延長到 SDDC Manager(#3,plink + pty/su)
3. 改 spec VSP pool 起點避開佔用 IP(#4)
4. `PATCH /v1/sddcs/{id}?skipValidations=true` 送 spec → resume LCM(活 VSP + 長 timeout)
5. 監控,**全程不刪 VSP**

> 對應腳本在本資料夾;`Set-VsanFtt0` / `Disable-HaAdmissionControl` / `Disable-NetworkRollback` /
> `Set-NestedReservations` / `Reset-TrunkPromiscuous` / `Connect-OfflineDepot` / `Watch-Bringup`。
> timeout 延長與 pty/su 細節另見 rtolab `timeout-tuning-operations-log.md`。

---

## 2026-07 全打掉重建血淚補充(七輪 VSP retry 換來的)

> 教訓總綱:**上面整套配方,全打掉重建後 appliance 會歸零 → 每次重建都要重跑,不能只做一次。** 這次沒重跑,靠一輪一輪撞才補齊。**現已收斂成一鍵 `Apply-VspRecipe.ps1`,重建後、進 VSP 前直接跑。**

### A. ⚠️ timeout/retry「兩台都要」,漏 Installer 照樣死
- `orchestrator.task.retry.max` 預設 **60** → Installer(10.0.1.4)的 monitor 任務重試 60 次就 `failed after 60 retries` 判死,**不管 timeout 設多大**。
- 這次只調了 SDDC Manager(10.0.1.18)漏了 Installer,前幾輪就算 bootstrap 已穩、崩潰降到個位數,仍被 Installer 的 60 次上限判死。
- **正解:`orchestrator.task.retry.max=240` 兩台(10.0.1.18 + 10.0.1.4)都要**。`Set-DomainManagerTimeouts.ps1` 的 `-Target` 預設就是兩台,別漏跑。

### B. bootstrap-vm apiserver 反覆 `connection refused`(OOM/swap)
- 症狀:平台套件裝到一半,`dial tcp 10.0.0.226:6443: connect: connection refused` 反覆 50 次、VSP VM clone→死→重建迴圈,不收斂。
- 根因:nested ESXi 被外層 swap → 內部 bootstrap k8s 的 apiserver/etcd 被 OOM/延遲幹掉。
- **正解 = 外層 `Set-NestedReservations`**(對 4 台 nested ESXi 設 CPU/Mem reservation)。實測:套上後崩潰 50 → 近乎 0。
- 反例:對「clone 來源 VM」設 `memoryReservationLockedToMax=True`(內層)**無效** —— 部署工具 clone 時會覆寫掉。有效的是**外層那層**。

### C. retry 前務必清 pool
- 殘留的 `bootstrap-vm-*` / `vcf-m02-vsp01-*` 佔住 `vspClusterSpec.ipv4Pool`(10.0.0.226-240),不刪 → `INIT0001 Validating configuration: IP x already in use` 直接 fail(連自己上一輪的 VSP node 佔 .227 都會擋)。
- 每次 retry 前:刪光這兩類 VM、ping 確認 226-240 全空,再 PATCH。

### D. 存取眉角(這次驗證)
- appliance root **不可 SSH**;`vcf` SSH 猛連會 **pam faillock**(密碼對也被拒,要停手 ~15 分)。
- **最穩:vCenter guest-ops(VMware Tools,`Invoke-VMScript` root/`VMware1!VMware1!`)** 繞過 sshd,不受 faillock 影響。SDDC Manager 走內層 vCenter、Installer 走外層 vCenter。
