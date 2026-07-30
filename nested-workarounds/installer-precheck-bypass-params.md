# VCF 9.1 Installer / SDDC Manager — bring-up precheck bypass 參數（實掃確認）

> ⚠️ **只 nested / homelab 用。Broadcom 不支援、production 勿用。**
> 跳過檢查只是讓 bring-up 流程「過關」；真環境底層若真有問題（MTU 不足、網路不通）
> 仍會在後續壞掉。nested 環境因封包不出實體網卡、jumbo/TEP 1600 打不出去才需要繞。

驗證環境：VCF Installer `install9.1`（Cloud Builder role, build **9.1.0.0100**）。
VCF Installer 與 SDDC Manager **共用同一份 domain-manager** → bring-up precheck = domain-manager validation。
所有 key 皆以 `python3 zipfile` 遞迴拆 4 顆 fat jar（domainmanager / commonsvcs / operationsmanager / lcm）
掃 `.class` 常數池的 `@Value("${...}")` / property key 逐條比對確認存在。

---

## 0. 生效方式

- 檔案：`/etc/vmware/vcf/domainmanager/application.properties`（domainmanager 進程讀）。
- 改完重啟：`systemctl restart domainmanager`（appliance root 不可直接 SSH → 用外層 vCenter guest-ops）。
- domainmanager Spring Boot 約需 60–150 秒才會 `Started DomainManagerApplication`；
  `systemctl is-active` 會馬上回 active（Type=simple），要看 log 的 `Started ... Application` 才算真的起來。

> **重要**：`.../domainmanager/application.properties` **只有 domainmanager 這個服務會讀**。
> 只被別的服務（operationsmanager / commonsvcs）引用的 key 放這裡是 **no-op**，要放到對應服務的 properties。

---

## 1. API 層開關（bring-up REST query param，jar 內確認存在）

| 參數 | 用法 |
|---|---|
| `skipValidations` | `POST /v1/sddcs?skipValidations=true` — 整段 precheck 一次關掉 |
| `skipValidation` / `skipPrecheck` / `skipHostValidation` / `dryRun` | 內部 validation controller 支援，細部 / host-level 跳過 |

---

## 2. domainmanager properties（28 條，放對地方 = 有效）

全部 `=true`。預設皆 `false`。

### 連線 / vmkping 類（12）
```properties
validation.disable.network.connectivity.check=true
validation.disable.ping.connectivity.check=true
validation.disable.vmotion.connectivity.check=true
validation.disable.vmotion.l3.gateway.connectivity.check=true
validation.disable.vsan.connectivity.check=true
validation.disable.vsan.disks.check=true
validation.disable.nfs.connectivity.check=true
validation.disable.nfs.configuration.connectivity.check=true
validation.disable.vvol.scsi.connectivity.check=true
validation.disable.datastore.availability.check=true
validation.disable.validate.domain.spec=true
validation.disable.remove.host.status.check=true
```

### NTP / NSX / 憑證（7）
```properties
ntp.config.skip.validation=true
nsx.domain.resources.validation.skip=true
nsx.vib.validation.skip=true
nsxt.management.resources.validation.skip=true
nsxt.skip.vlcm.check=true
nsxt.disable.certificate.validation=true
vcf.skip.vds.check.nsx.overlay.management=true
```

### guardrails / default-cluster（5）
```properties
vcf.skip.dayn.guardrails=true
vcf.skip.nsx.dayn.guardrails=true
skip.oob.network.validation.cluster=true
skip.validate.host.networkpool.in.default.cluster=true
skip.validate.nsx.config.in.default.cluster=true
```

### 其他 precheck（4）
```properties
feature.vcf.skip.duplicate.pg.names.check=true
fsm.ValidateHostNfsDataStoreAction.skipCheck=true
proxy.configuration.validation.skip=true
vc.ring.topology.health.check.skip=true
```

---

## 3. 這 3 條 domainmanager 不讀 → 要放對應服務的 properties

放在 domainmanager 的 properties 是 **無效（no-op）**：

| 參數 | 讀取的服務 | 該放的檔案 | 備註 |
|---|---|---|---|
| `commission.skip.ntp.validation` | operationsmanager | `/etc/vmware/vcf/operationsmanager/application.properties` | fresh bring-up NTP 已被 `ntp.config.skip.validation` 蓋掉 |
| `vcf.import.guardrails.vcenter.vm.dvpg.skip` | operationsmanager | 同上 | 只對 VCF Import / brownfield 有意義，fresh bring-up 不會碰 |
| `identity.user.skip.validation` | commonsvcs（共用 lib） | 實務放 operationsmanager | identity/user 驗證 |

---

## 4. vmkping 沒有單一開關

`EsxiHostNetworkingUtil.vmkping` / `EsxCommands.ESXCLI_VMKPING_COMMAND` 是底層工具，
由各 `Validate*ConnectivityAction` 呼叫。關 vmkping = 關對應的 `validation.disable.*.connectivity.check`：

| vmkping 檢查（action） | property |
|---|---|
| 管理 ping（HostNetworkValidator） | `validation.disable.ping.connectivity.check` |
| host 管理網路（ValidateHostNetworkConnectivityAction） | `validation.disable.network.connectivity.check` |
| vMotion | `validation.disable.vmotion.connectivity.check` |
| vMotion L3 gateway | `validation.disable.vmotion.l3.gateway.connectivity.check` |
| vSAN | `validation.disable.vsan.connectivity.check` |
| NFS / NFS config | `validation.disable.nfs.connectivity.check` / `...nfs.configuration...` |
| vVol/VASA | `validation.disable.vvol.scsi.connectivity.check` |

- MTU 的 jumbo 探測（`vmkping -d -s`）**內含在這些 connectivity check 裡**，沒有獨立 MTU skip 旗標。
- `vds.default.mtu`（預設 9000）只是「設定成多少」，不是檢查開關。
- **`nsxt.mtu.validation.skip` 在 9.1.0.0100 全 jar 0 命中 = no-op**（9.0 殘留 / William Lam blog 的舊 key）。

---

## 5. 「灌參數服務能否啟動」實測（2026-07-30）

在 throwaway installer（fresh deploy）把上面 domainmanager 的參數全寫入 → `systemctl restart domainmanager`：

- 重啟後 log 出現全新的 `Started DomainManagerApplication in ~64s`。
- systemd：`active/running`、`NRestarts=0`（無 crash loop）、`ExecMainStatus=0`。
- domainmanager.log **無** `Failed to bind` / `Could not resolve placeholder` 等 property-binding 錯誤。
- 登入頁 `https://<installer>/` → 導向 `/vcf-installer-ui/`（HTTP 200, `<title>VCF Installer</title>`）。
- 登入 API：`POST /v1/tokens`（帳號 `admin@local`）→ 200 拿到 token；帶 Bearer 打 `GET /v1/sddcs` → 200。

**結論**：這些 override property 設 `true` 不會擋 domainmanager 啟動；
Spring 對「多出來 / 未被消費的 property」也只是忽略。

---

## 附：驗證手法（可複現）

- 掃 property key：`python3` 用 `zipfile` 遞迴拆 fat jar（含 `BOOT-INF/lib/**/*.jar`），
  掃 `.class` 常數池的 `${...}` 與 dotted key，逐條比對是否命中、命中在哪顆 jar（= 哪個服務讀）。
- appliance 進不去 SSH（22 refused）→ 一律走**外層 vCenter guest-ops**（VMware Tools）跑腳本；
  govc guest.run 有「多字 `bash -c` 被拆」的空格坑 → 把指令寫成 `.sh` 上傳再 `bash /tmp/x.sh` 才穩。
