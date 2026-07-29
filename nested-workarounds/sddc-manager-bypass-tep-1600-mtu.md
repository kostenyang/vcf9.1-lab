# SDDC Manager 能不能 bypass ESX TEP 1600 MTU check?(VCF 9.1 實測)

> nested VCF lab 常卡 **TEP 1600 MTU 檢查**(巢狀 vSwitch/實體網路給不到 1600+ MTU)。
> William Lam 寫過怎麼在 **VCF Installer(bring-up)** 繞過,但沒回答 **day-N / SDDC Manager**(留言區有人問、作者未答)。
> 本文用 **guest-ops 直接拆 VCF 9.1 SDDC Manager 的 domain-manager jar** 求證,給出實測答案。

**來源 blog**:William Lam — [Bypassing the ESX Tunnel Endpoint (TEP) 1600 MTU check in the VCF Installer](https://williamlam.com/2026/01/bypassing-the-esx-tunnel-endpoint-tep-1600-mtu-check-in-the-vcf-installer.html)(VCF **9.0**、VCF Installer appliance)。

---

## 一、blog 的原招(VCF Installer / bring-up)

SSH 進 **VCF Installer** appliance(vcf user),在 domain-manager 設定檔加兩行,再重啟服務:
```bash
# /etc/vmware/vcf/domainmanager/application.properties
validation.disable.network.connectivity.check=true
nsxt.mtu.validation.skip=true
```
```bash
echo 'y' | /opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh
```
> 最小 MTU 1600 是給 NSX host 間 **TEP(Tunnel Endpoint)** overlay 流量用的;實體/巢狀網路達不到就會卡在 validation。

---

## 二、實測:同樣招數搬到 SDDC Manager 行不行?

環境:本 lab **VCF 9.1** SDDC Manager `vcf-m02-sddcm01.home.lab`(VMware Cloud Foundation Manager Virtual Appliance)。
方法:`govc guest.run`(VMware Tools)進 appliance,`python3` 拆 `/opt/vmware/vcf/domainmanager/vcf-domain-manager.jar`(fat jar, 624 entries)掃 property key 字串。

### 2-1 基礎設施同不同?→ **完全相同**
| 檢查 | 結果 |
|---|---|
| `/etc/vmware/vcf/domainmanager/application.properties` | ✅ 存在(605B,owner `vcf_domainmanager`) |
| `/opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh` | ✅ 存在 |
| `domainmanager` 服務 | ✅ active(單一 `vcf-domain-manager.jar`) |

→ SDDC Manager 跟 VCF Installer **共用同一個 domain-manager 元件**,所以 application.properties 這條路本身通。

### 2-2 那兩個 key 認不認得?→ **一個認、一個不認**
掃 jar class 常數池:
| blog 的 key | 9.1 SDDC Manager jar 命中 | 判定 |
|---|---|---|
| `validation.disable.network.connectivity.check` | **1 命中** — `libvalidation-plugin.jar → com/vmware/evo/sddc/validation/action/AuditSinglePortgroupAction.class` | ✅ **認得** |
| `nsxt.mtu.validation.skip` | **0 命中** | ❌ **9.1 SDDC Manager 沒這個 key** |

### 2-3 9.1 的 MTU 檢查其實長這樣
掃到的 MTU 驗證機制(不是單一開關,是驗證 action + 一致性檢查):
- 驗證類別:**`ValidateNsxtGlobalConfigMtuAction`**、`validateVdsSpecsForMtu`、`validateMtuThresholdComplianceWithException`、`checkMtuConsistency`
- 錯誤碼:`SPEC_VALIDATION_NFS_MTU_INCONSISTENT_FOR_HOSTS_IN_CLUSTER`、`SPEC_VALIDATION_VSAN_MTU_INCONSISTENT_*`、`SPEC_VALIDATION_VMOTION_MTU_INCONSISTENT_*`
- 訊息:`The MTU {} set for the VDS {} is not valid. MTU should be atleast {}`
- 可調預設:**`vds.default.mtu`(預設 9000)** ← 設定值不是 skip
- 條件式 skip(非旗標,是狀態):`NSX Global Config MTU not set, skipping validation` / `Domain ID is blank, skipping...` 等

---

## 三、結論:**能,但用法跟 9.0 blog 不同 —— 而且 SDDC Manager 的 bypass 開關更多**

`nsxt.mtu.validation.skip` 在 9.1 SDDC Manager 無效(不存在),**但同一個 `application.properties` 認得一整族連線/驗證 skip 旗標**(以下 key 均為 domain-manager jar 內實測存在的 property 字串),放同一個檔、同樣 `sddcmanager_restart_services.sh` 重啟即生效:

### 直接對應「TEP/連線可達性」檢查(1600 大封包測試就在這層)
```properties
validation.disable.network.connectivity.check=true        # blog 那個,SDDC Manager 也吃(host 間連線 audit)
validation.disable.ping.connectivity.check=true           # ping/可達性
validation.disable.vmotion.connectivity.check=true
validation.disable.vmotion.l3.gateway.connectivity.check=true
validation.disable.vsan.connectivity.check=true
validation.disable.nfs.connectivity.check=true
validation.disable.nfs.configuration.connectivity.check=true
validation.disable.vvol.scsi.connectivity.check=true
```

### NSX / overlay / VDS / day-N(這才是「加後續 workload domain」要的)
```properties
vcf.skip.nsx.dayn.guardrails=true                 # ★ 直接回答 blog 留言「day-N 也適用嗎」
vcf.skip.vds.check.nsx.overlay.management=true    # 跳 overlay VDS 檢查
skip.oob.network.validation.cluster=true          # 跳 out-of-band 網路驗證
skip.validate.host.networkpool.in.default.cluster=true
skip.validate.nsx.config.in.default.cluster=true
nsx.domain.resources.validation.skip=true
nsxt.management.resources.validation.skip=true
nsx.vib.validation.skip=true
nsxt.skip.vlcm.check=true
nsxt.disable.certificate.validation=true
```

### 套用步驟(SDDC Manager,同 blog 手法)
```bash
# SSH / guest-ops 進 vcf-m02-sddcm01,以 root(或 vcf → su)
cat >> /etc/vmware/vcf/domainmanager/application.properties <<'EOF'
validation.disable.network.connectivity.check=true
validation.disable.ping.connectivity.check=true
vcf.skip.nsx.dayn.guardrails=true
vcf.skip.vds.check.nsx.overlay.management=true
EOF
echo 'y' | /opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh
```
> 巢狀環境本 lab 的 guest-ops 跑法:`govc guest.run -vm '/m01-dc01/vm/vcf-m02-sddcm01' -l root:<pw> ...`(appliance STIG 擋 SSH 時)。
> ⚠️ `application.properties` 的行**別帶多餘空格**;`sddcmanager_restart_services.sh` 重啟 domain-manager 約 1–2 分。

---

## 三之二、VCF Installer 9.1 也適用嗎?→ **適用**(但同一個 key 之謎已釐清)

William Lam 另有 **9.1 專文**同時涵蓋 Installer + SDDC Manager:
[VCF 9.1 — Comprehensive VCF Installer & SDDC Manager Configuration Workarounds for Lab Deployments](https://williamlam.com/2026/05/vcf-9-1-comprehensive-vcf-installer-sddc-manager-configuration-workarounds-for-lab-deployments.html)。
他 9.1 專文**仍列** `validation.disable.network.connectivity.check=true` **+** `nsxt.mtu.validation.skip=true`(放 domainmanager/application.properties,`systemctl restart domainmanager`),Installer 與 SDDC Manager 手法相同。

**但**我對本 lab **9.1.0.0100** 的 domain-manager/operations-manager fat jar 做過深掃(5 jar、多層 nested、全 bytes、0 read error):
| 字串 | 命中 |
|---|---|
| `nsxt.mtu.validation.skip` | **0** |
| `nsxt.mtu` / `mtu.validation` | **0**(連 checkId 都不在,排除動態組 key) |
| `validation.disable.network.connectivity.check` | ✅ 有(`AuditSinglePortgroupAction`) |

→ 判讀:**在 9.1.0.0100 build,`nsxt.mtu.validation.skip` 是 no-op(沿用自 9.0 blog 的殘留行,無害但不生效)**;真正讓 TEP/大封包可達性檢查過關的是 **`validation.disable.network.connectivity.check=true`**。William Lam 兩行都放 → 就算 mtu 那行沒作用,connectivity 那行也把事情辦了(所以他的做法 9.1「照樣能過」,只是原因跟字面不同)。

**因為 Installer 與 SDDC Manager 共用同一份 9.1 domain-manager**,以上結論 **Installer 9.1 同樣成立**:放 `validation.disable.network.connectivity.check=true` 即可過 MTU/TEP 檢查;`nsxt.mtu.validation.skip=true` 放著無害但別指望它。(不同 9.1.x patch 若那 key 又出現,兩行都放最保險。)

- 重啟兩種都行:`systemctl restart domainmanager`(Lam 9.1)或 `sddcmanager_restart_services.sh`(blog 9.0)。
- **另有 API 繞法**(bring-up,社群/KB 提到):`POST https://<installer>/v1/sddcs?skipValidations=true`(先確認只剩 MTU 一項 validation 卡著再用)。

## 四、⚠️ 重要警語(誠實話)
- 這些是 **domain-manager 內部、未公開的 validation-skip property**(拆 jar 得到),**Broadcom 不支援、prod 千萬別用**。純 **nested/homelab** 為了繞實體網路做不到 1600 MTU 才用。
- **1600 MTU 有它的理由**:NSX overlay(Geneve)封裝需要 >1500 的 MTU;真環境 MTU 不夠 → overlay 流量會斷 → workload 網路實際會壞。跳過檢查只是讓 **bring-up/day-N 流程過關**,不會讓底層網路真的能跑 —— nested lab 因為 host 間走同一台實體/巢狀 switch、封包不出實體網卡才「能動」。
- 跳 connectivity check 也會一併關掉 vSAN/vMotion/NFS 的連線前檢,等於把 pre-flight 保護拿掉,出事更難查。只加你真的需要的那幾條。

## 五、驗證方法(可複現)
1. `govc guest.run` 進 SDDC Manager,`python3` `zipfile` 遞迴拆 `vcf-domain-manager.jar`(含 `BOOT-INF/lib/**/*.jar`)。
2. 掃 `.class` 常數池找 property key 字串 / `${...}` `@Value` 佔位符。
3. 本文所有 key 均為 **9.1 `vcf-domain-manager.jar` 內實測存在**的字串(212 個 validation/skip 類 key 中的網路/MTU/NSX 子集)。腳本留在本 lab scratchpad(`sddcm-jarscan.py` / `sddcm-mtuscan.py` / `sddcm-propscan.py`)。

## 相關
- 上游:[William Lam — TEP 1600 MTU bypass(VCF Installer)](https://williamlam.com/2026/01/bypassing-the-esx-tunnel-endpoint-tep-1600-mtu-check-in-the-vcf-installer.html)
- 本 repo `nested-workarounds/` 其他巢狀化繞法。
