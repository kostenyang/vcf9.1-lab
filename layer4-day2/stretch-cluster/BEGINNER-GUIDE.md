# 小白操作手冊:把 VCF 管理叢集變成 vSAN Stretched Cluster

> 這份給第一次做的人。每一步都寫「做什麼、為什麼、打什麼、會看到什麼、出錯怎麼辦」。
> 照順序做,不要跳。整趟大約半天(等待時間居多)。

---

## 0. 先弄懂幾個名詞(1 分鐘)

| 名詞 | 白話 |
|---|---|
| **SDDC Manager** | VCF 的大腦,網址 `https://192.168.120.4`。我們所有「指令」都是打給它的 API。 |
| **API** | 不用點網頁,用命令列送 JSON 給 SDDC Manager 叫它做事。這份文件的腳本幫你把 JSON 包好了。 |
| **vCenter** | 管 ESXi 主機的那台,網址 `https://192.168.120.3`。有些步驟要在這裡點滑鼠。 |
| **Cluster** | 一群 ESXi 主機。我們要改的叫 `vcf-m01-cl01`。 |
| **Stretched cluster** | 把一個 cluster 拆成兩個機房(AZ1、AZ2),資料兩邊各存一份,一邊掛了另一邊還能跑。 |
| **AZ**(Availability Zone) | 「機房」。AZ1 = esx01/02/03,AZ2 = esx05/06/07。**兩邊台數要一樣**。 |
| **Witness** | 第三個地方的一台小 ESXi(`esx-witness`),不放資料,只當裁判(兩邊斷線時決定誰活著)。 |
| **Commission** | 把一台新 ESXi「登記」到 SDDC Manager,登記完才能加進 cluster。 |
| **Task** | 你叫 SDDC Manager 做的每件事都變成一個 task,有 id,可以查進度、失敗了可以 retry。 |
| **Validation** | 真的做之前先「預檢」。預檢過了再做。 |
| **vSAN policy** | 資料要存幾份的規則。stretch 後 VCF 預設每筆存 4 份,我們的硬碟不夠,要改成 2 份。 |
| **MTU 9000** | 網路封包大小設定。vSAN 用大封包(9000),witness 也要一樣,不然最後一步會失敗。 |

---

## 1. 你需要準備的東西

- [ ] 一台能連到 `192.168.120.0/24` 的電腦(跳板機 `192.168.110.85` 或你的 Windows)
- [ ] 上面有 **Python 3**(打 `python --version` 有版本就行)
- [ ] 這個資料夾的檔案:`vcf_stretch.py`、`witness_prep.py`、`vsan_policy_sftt0.py`
- [ ] 帳號密碼:SDDC Manager / vCenter 的 `administrator@vsphere.local`;ESXi 的 `root`
- [ ] vCenter 的 datacenter 名稱:`vcf-m01-dc01`;network pool 名稱:`m01-np01`
- [ ] 三台新 ESXi(esx05/06/07)和一台 witness(esx-witness)**已經裝好、開機、DNS 可以查到**(這部分是別的文件,見第 3 步)

安裝 pyvmomi(只有 witness_prep.py 和 vsan_policy_sftt0.py 需要):

```bash
pip install pyvmomi
```

---

## 2. 第一步:確認能連上 SDDC Manager

**做什麼**:設定密碼、測試腳本能不能登入。

打開終端機(Windows 用 Git Bash 或 PowerShell;跳板機用 ssh 進去),進到腳本資料夾:

```bash
cd layer4-day2/stretch-cluster
export SDDC_HOST=192.168.120.4
export SDDC_USER=administrator@vsphere.local
export SDDC_PASS='你的密碼'
```

> PowerShell 的話改成:`$env:SDDC_HOST='192.168.120.4'; $env:SDDC_USER='administrator@vsphere.local'; $env:SDDC_PASS='你的密碼'`

然後:

```bash
python vcf_stretch.py token
```

**你會看到**:`token OK: eyJhbGciOiJIUzI1NiJ9...` → 成功。

再看一下現在有什麼:

```bash
python vcf_stretch.py clusters
python vcf_stretch.py hosts
python vcf_stretch.py pools
```

**你會看到**(類似):

```
b1fbf71d-...  vcf-m01-cl01     stretched=False hosts=4
fcb89c28-...  esx01.alan.lab   ASSIGNED   pool=m01-np01
...
72a22f84-...  m01-np01
```

`stretched=False`、4 台主機、一個 pool。前面那串是 id,腳本自己會用,你不用記。

**出錯怎麼辦**
- `請設 SDDC_PASS 環境變數` → 密碼沒 export,回去打 `export SDDC_PASS='...'`
- `HTTP Error 401` → 密碼錯
- 連不上 / timeout → 網路不通,先 `ping 192.168.120.4`

---

## 3. 第二步:把 esx04 從 cluster 拿掉(4 台變 3 台)

**為什麼**:stretched cluster 兩邊主機數要一樣。我們只有資源再加 3 台,所以 AZ1 也要是 3 台。

### 3-1 先在 vCenter 開 esx04 的 SSH(重要,不開會卡住)

1. 瀏覽器開 `https://192.168.120.3/ui`,登入 `administrator@vsphere.local`
2. 左邊點 **esx04.alan.lab** → 上面 **Configure** → 左邊 **System → Services**
3. 找到 **SSH**,點 **START**;再點 **EDIT STARTUP POLICY** → 選 **Start and stop with host** → OK

### 3-2 打命令

```bash
python vcf_stretch.py remove-host --cluster vcf-m01-cl01 --host esx04.alan.lab --decommission
```

**你會看到**:

```
validation: COMPLETED SUCCEEDED
PATCH compaction -> 202 Removing host(s) from cluster ...
[10:05:01] In Progress 3/45 ['Enter Maintenance Mode on ESXi Hosts']
...
[10:20:12] Successful 45/45 []
DELETE host -> 202 Decommissioning host(s) ...
[10:22:30] Successful 5/5 []
```

大約 15~20 分鐘。看到兩個 `Successful` 就完成。

**確認**:`python vcf_stretch.py hosts` → 只剩 esx01/02/03。

**出錯怎麼辦**
- 卡在 `Enter Maintenance Mode on ESXi Hosts` 超過 10 分鐘 → 就是 3-1 的 SSH 沒開。去開,task 會自己繼續。
- validation 失敗 → 訊息會直接印出來,照訊息處理。

---

## 4. 第三步:準備新主機(這步是點滑鼠,不是 API)

**做什麼**:讓 esx05/06/07 和 esx-witness 這四台「可以被登記」。

每台新 ESXi 要確認四件事(在 ESXi 的網頁 `https://192.168.120.65` 等,或 vCenter 裡):

| 檢查 | 怎麼確認 | 不對怎麼改 |
|---|---|---|
| DNS 查得到 | 在跳板機 `nslookup esx05.alan.lab 192.168.110.85` 有 IP | 在 dnsmasq(110.85)的 `/etc/dnsmasq.d/alan-lab.conf` 加 `host-record=esx05.alan.lab,esx05,192.168.120.65`,`sudo systemctl restart dnsmasq` |
| SSH 開著 | vCenter → 主機 → Configure → Services → SSH 是 Running | 同 3-1 的方法 START + policy |
| vmk0 只有 Management | vCenter → 主機 → Configure → Networking → VMkernel adapters → vmk0 → Enabled services 只有 **Management** | 點 vmk0 → EDIT → 把 vMotion、vSAN 打勾拿掉 |
| nested vSAN 的 6 個 advanced settings | 跑 `../Apply-NestedVsanWorkarounds.ps1 -DryRun` 看 | 拿掉 `-DryRun` 跑一次 |

四台都確認完再往下。

---

## 5. 第四步:登記(commission)AZ2 三台

**做什麼**:把 esx05/06/07 登記到 SDDC Manager。先預檢,預檢過再真的做。

```bash
python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password 'ESXi的root密碼' --validate-only
```

**你會看到**:`validation: COMPLETED SUCCEEDED` → 預檢過了。

> 如果你的電腦查不到 `esx05.alan.lab`(Windows 常見),改寫成 `esx05.alan.lab=192.168.120.65,esx06.alan.lab=192.168.120.66,esx07.alan.lab=192.168.120.67`。

預檢過了就把 `--validate-only` 拿掉再跑一次:

```bash
python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password 'ESXi的root密碼'
```

**你會看到**:`POST hosts -> 202 Commissioning host(s) ...` 然後每分鐘一行進度,最後 `Successful`。大約 10 分鐘。

**確認**:`python vcf_stretch.py hosts` → esx05/06/07 出現,狀態 `UNASSIGNED_USEABLE`。

**出錯怎麼辦**
- `Host must have only Management tag enabled on the VMkernel` → 第 4 步的 vmk0 沒清乾淨
- `SSL thumbprint mismatch` → 主機憑證換過了,再跑一次就會重算
- 連 ESXi 失敗 → root 密碼錯,或 SSH 沒開

---

## 6. 第五步:準備 witness

**做什麼**:把 esx-witness 加進 vCenter(**不要**放進 cluster),幫它做一張 vSAN 用的網卡。

```bash
python witness_prep.py --vc 192.168.120.3 --vc-pass 'vCenter密碼' --dc vcf-m01-dc01 \
    --witness esx-witness.alan.lab --witness-pass 'ESXi的root密碼' --vlan 140 --ip 192.168.140.68
```

> 查不到 DNS 就多加 `--witness-ip 192.168.120.68`。

**你會看到**:

```
adding standalone host esx-witness.alan.lab
vSwitch0 MTU -> 9000
portgroup vsan-witness VLAN 140 created
vmk1 192.168.140.68/255.255.255.0 MTU 9000 created
vmk1 tagged vsan
DONE. 現在到 witness SSH 驗 jumbo ...
```

### 6-1 一定要做的檢查:大封包 ping

ssh 進 witness(`ssh root@192.168.120.68`),打:

```bash
for ip in 5 6 7 8 9 10; do vmkping -I vmk1 -s 8972 -d -c 2 192.168.140.$ip | tail -1; done
```

**你會看到**:六行都是 `2 packets transmitted, 2 packets received`。

> 這些 140.5~140.10 是 cluster 六台主機的 vSAN IP(SDDC Manager 從 pool 發的,不是主機的管理 IP)。
> **只要有一行 `0 packets received`,不要往下做**,先解決(通常是外層 trunk 或 vSwitch 的 MTU 不是 9000)。

在 vCenter 確認:左邊樹 `vcf-m01-dc01` 下面直接有 `esx-witness.alan.lab`(不在 cluster 底下)。

---

## 7. 第六步:Stretch(主戲)

### 7-1 產生設定檔

```bash
python vcf_stretch.py gen-stretch-spec --cluster vcf-m01-cl01 --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab \
    --witness esx-witness.alan.lab --witness-ip 192.168.140.68 --witness-cidr 192.168.140.0/24 --overlay-vlan 150
```

**你會看到**:一大段 JSON,最後 `written stretch-spec.json`。這個檔案就是要送給 SDDC Manager 的「申請單」。

### 7-2 預檢

```bash
python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --validate-only
```

**你會看到**:`validation: COMPLETED SUCCEEDED`。沒過的話會列出哪一條沒過,照訊息處理。

### 7-3 真的送出

```bash
python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --watch
```

**你會看到**:

```
PATCH stretch -> 202 Stretch vSAN Cluster - vcf-m01-cl01 in VMware Cloud Foundation task 523a173a-...
[22:19:31] In Progress 0/114 []
[22:20:02] In Progress 38/114 ['Validate vMotion Network Connectivity']
...
[22:27:07] In Progress 81/114 ['Update vSAN Storage Profile']
...
[22:29:08] In Progress 84/114 ["Remediate ESXi Host(s) to be Compliant with Cluster's Image"]
```

**把那串 task id 記下來**(也會存在 `stretch-task.txt`),後面 retry 要用。

整個大約 30 分鐘。**看到 `Update vSAN Storage Profile` 過了之後,馬上去做第 8 步**(可以另開一個終端機)。

---

## 8. 第七步:把資料份數從 4 改成 2(nested 環境一定要做)

**為什麼**:VCF 在剛才那步把規則改成「每筆資料存 4 份」。我們的 vSAN 只有 1500GB,裝不下,而且會拖很久。改成「每個機房 1 份、共 2 份」。

```bash
python vsan_policy_sftt0.py --vc 192.168.120.3 --vc-pass 'vCenter密碼' --policy 'vcf-m01-cl01 vSAN Storage Policy'
```

**你會看到**:

```
目前: {'hostFailuresToTolerate': 1, 'subFailuresToTolerate': 1, ...}
改後: {'hostFailuresToTolerate': 1, 'subFailuresToTolerate': 0, ...}
  reapply nsx01      success
  reapply vcsa       success
  ...
  reapply vcf-services-runtime-template-...   error The operation is not supported   ← 這個正常,忽略
compliance:
  nsx01   {'compliant'}
  ...
```

---

## 9. 第八步:等它失敗一次,然後 retry(是的,幾乎一定會失敗一次)

第 7 步的 task 最後一段 `Remediate ESXi Host(s)...` 很可能失敗,畫面會印:

```
[22:44:23] Failed 89/114 []
FAILED: Remediate ESXi Host(s) to be Compliant with Cluster's Image
  errorCode: VLCM_REMEDIATE_PERSONALITY_FAILED ... Health Check for 'vcf-m01-cl01' failed
```

**不要慌,這是正常的**。它的意思是「vSAN 現在還沒健康到可以讓主機進維護模式」。原因兩個,照順序檢查:

### 9-1 資料還在同步(resync)

在 vCenter:左邊點 **vcf-m01-cl01** → **Monitor** → **vSAN → Resyncing Objects**。
有東西在跑就等,等到 **0**(第 8 步做了的話會快很多,大約 1 小時)。

### 9-2 vSAN 健康檢查有紅燈

vCenter:**vcf-m01-cl01** → **Monitor** → **vSAN → Skyline Health**,點 **RETEST**。
- 有紅色的項目 → 點開看。最常見是 `MTU check (ping with large packet size)` = 第 6-1 步沒通。修好再 RETEST。
- 黃色(例如 Disk Balance)可以不管。

### 9-3 兩個都好了 → retry

```bash
python vcf_stretch.py retry <剛才記的 task id>
```

**你會看到**:`retry -> 200 {}` 然後又開始跑進度,大約 15 分鐘後:

```
[01:46:27] Successful 110/110 []
```

**出錯怎麼辦**
- retry 又失敗、錯誤一樣 → 回到 9-1 / 9-2,一定還有一個沒綠。resync 沒歸零、health 沒綠,retry 必敗。
- 想看真正原因(進階):ssh 到 vCenter(`root@192.168.120.3`,先打 `shell`),
  `grep 'Overall vSAN cluster health' /var/log/vmware/vmware-updatemgr/vum-server/vmware-vum-server.log | tail -1`
  和 `grep -B2 'health : red' /var/log/vmware/vsan-health/vmware-vsan-health-summary-result.log | tail -5`

---

## 10. 第九步:確認做完了

```bash
python vcf_stretch.py clusters
```

**你會看到**:`vcf-m01-cl01  stretched=True hosts=6`。

vCenter:**vcf-m01-cl01** → **Configure** → **vSAN → Fault Domains**,應該是:

- Configuration type:**Stretched cluster**
- Witness host:esx-witness.alan.lab
- 左邊 `vcf-m01-cl01_primary-az-faultdomain (preferred)`:esx01 / esx02 / esx03
- 右邊 `vcf-m01-cl01_secondary-az-faultdomain`:esx05 / esx06 / esx07

看到這個畫面就完成了。

---

## 11. 一頁速查(做過一次之後看這個就夠)

```bash
export SDDC_HOST=192.168.120.4 SDDC_USER=administrator@vsphere.local SDDC_PASS='...'
python vcf_stretch.py token
python vcf_stretch.py remove-host --cluster vcf-m01-cl01 --host esx04.alan.lab --decommission        # 先開 esx04 SSH
#   → 裝好 esx05/06/07 + witness;DNS、SSH、vmk0 只留 Management
python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password '...' --validate-only
python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password '...'
python witness_prep.py --vc 192.168.120.3 --vc-pass '...' --dc vcf-m01-dc01 --witness esx-witness.alan.lab --witness-pass '...' --vlan 140 --ip 192.168.140.68
#   → witness 上 vmkping -I vmk1 -s 8972 -d 192.168.140.5~10 全通
python vcf_stretch.py gen-stretch-spec --cluster vcf-m01-cl01 --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --witness esx-witness.alan.lab --witness-ip 192.168.140.68 --witness-cidr 192.168.140.0/24 --overlay-vlan 150
python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --validate-only
python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --watch
python vsan_policy_sftt0.py --vc 192.168.120.3 --vc-pass '...' --policy 'vcf-m01-cl01 vSAN Storage Policy'   # Update vSAN Storage Profile 過了就做
#   → 失敗?等 resync=0 + Skyline Health 綠
python vcf_stretch.py retry <taskId>
python vcf_stretch.py clusters     # stretched=True
```

## 12. 常見問題

| 狀況 | 原因 | 怎麼辦 |
|---|---|---|
| 腳本說找不到 cluster / host | 名字打錯(要完整 FQDN) | `python vcf_stretch.py hosts` 照抄 |
| Windows 查不到 `*.alan.lab` | 你的電腦 DNS 不是 110.85 | 用 `fqdn=ip` 寫法,或去跳板機跑 |
| 跑一半終端機關了 | task 還在 SDDC Manager 跑,沒事 | `python vcf_stretch.py watch <taskId>` 接回來看 |
| token 過期(跑超過 1 小時後報 401) | token 一小時失效 | 腳本每次執行會重拿,重跑該命令即可 |
| 主機 SSH 又被關了 | VCF 做完事會把 SSH 關回去 | 需要時再去 vCenter 開 |
| retry 一直失敗 | resync 沒歸零或 health 有紅 | 第 9 步,兩個都要綠 |

更多細節:`FLOW.md`(流程一頁版)、`README.md`(腳本與 API 對照)、`STRETCH-RUNBOOK.md`(完整實作紀錄)。
