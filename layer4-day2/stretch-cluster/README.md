# vcf-stretch-cluster — 用 SDDC Manager API 把 VCF 9.1 mgmt cluster 變 vSAN Stretched Cluster(3+3+witness)

> 主要維護處是獨立 repo [kostenyang/vcf-stretch-cluster](https://github.com/kostenyang/vcf-stretch-cluster)(含 shots / shots-redo 截圖與 docx);這裡是同步副本(只有腳本與文件)。

alan.lab 2026-09-18/19 實測。VCF 的 stretch **只有 API**(SDDC Manager UI 沒有),整套流程包成幾支腳本。
**第一次做的人看 [`BEGINNER-GUIDE.md`](BEGINNER-GUIDE.md)(逐步、含預期輸出與出錯處理);一頁版流程看 [`FLOW.md`](FLOW.md)**;完整實作紀錄與踩雷看 `STRETCH-RUNBOOK.md`。

| 腳本 | 需要 | 做什麼 |
|---|---|---|
| `vcf_stretch.py` | 純標準庫 | SDDC Manager API:移除主機、commission、產 stretch spec、驗證、stretch、看/盯/retry task |
| `vcf_stretch.sh` | bash + curl + jq | 同上的 shell 版(跳板機直接跑;spec 檔自己寫) |
| `curl-cheatsheet.sh` | curl + jq | 一行一個 curl,複製貼上手打用 |
| `witness_prep.py` | pyvmomi | witness 加進 vCenter(cluster 外)+ vSAN vmk(VLAN / IP / **MTU 9000** / vsan tag) |
| `vsan_policy_sftt0.py` | pyvmomi | stretch 後把 VCF 套的 PFTT=1/SFTT=1 改成 SFTT=0 並 reapply(容量不夠 4 份時) |

## 順序

```bash
export SDDC_HOST=192.168.120.4 SDDC_USER=administrator@vsphere.local SDDC_PASS='...'

# 0. 看 inventory
python vcf_stretch.py clusters; python vcf_stretch.py hosts; python vcf_stretch.py pools

# 1. 兩邊主機數要相等 → 4 台變 3 台(先在 vCenter 把該主機 SSH 開起來,不然卡 Enter Maintenance Mode)
python vcf_stretch.py remove-host --cluster vcf-m01-cl01 --host esx04.alan.lab --decommission

# 2. AZ2 三台 nested ESXi 裝好、DNS 加好、SSH 開、vmk0 只留 Management tag
python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password '...' --validate-only
python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password '...'

# 3. witness
python witness_prep.py --vc 192.168.120.3 --vc-pass '...' --dc vcf-m01-dc01 \
    --witness esx-witness.alan.lab --witness-pass '...' --vlan 140 --ip 192.168.140.68
#   → 到 witness 上 vmkping -I vmk1 -s 8972 -d 每台 cluster 主機的 vSAN IP(140.5 起),全通才繼續

# 4. stretch
python vcf_stretch.py gen-stretch-spec --cluster vcf-m01-cl01 --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab \
    --witness esx-witness.alan.lab --witness-ip 192.168.140.68 --witness-cidr 192.168.140.0/24 --overlay-vlan 150
python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --validate-only
python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --watch

# 5.(nested 容量不夠 4 份時)stretch 的 "Update vSAN Storage Profile" 一過就改 policy
python vsan_policy_sftt0.py --vc 192.168.120.3 --vc-pass '...' --policy 'vcf-m01-cl01 vSAN Storage Policy'

# 6. 掛在 Remediate ESXi → 等 resync 歸零 + vSAN Skyline Health 綠 → retry
python vcf_stretch.py task <taskId>
python vcf_stretch.py retry <taskId>
```

## shell 版(跳板機 110.85 `~/vcf/stretch-cluster/`,已實測)

```bash
export SDDC_PASS='...'
./vcf_stretch.sh clusters | hosts | pools | get /v1/hosts
./vcf_stretch.sh remove-host vcf-m01-cl01 esx04.alan.lab --decommission
./vcf_stretch.sh commission  hosts.json [--validate-only]
./vcf_stretch.sh validate    vcf-m01-cl01 stretch-spec.json
./vcf_stretch.sh stretch     vcf-m01-cl01 stretch-spec.json
./vcf_stretch.sh task|watch|retry <taskId>
```

## API 對照(腳本裡每個子命令打的 endpoint)

| 子命令 | API |
|---|---|
| token | `POST /v1/tokens` → `accessToken`,之後 `Authorization: Bearer` |
| hosts / clusters / pools | `GET /v1/hosts` `/v1/clusters` `/v1/network-pools` |
| remove-host | `POST /v1/clusters/{id}/validations` → `PATCH /v1/clusters/{id}` (`clusterCompactionSpec`) → `DELETE /v1/hosts` |
| commission | `POST /v1/hosts/validations` → `POST /v1/hosts` (`sslThumbprint` = SHA-1) |
| stretch | `POST /v1/clusters/{id}/validations` → `PATCH /v1/clusters/{id}` (`clusterStretchSpec`) |
| task / watch | `GET /v1/tasks/{id}`(`subTasks` 巢狀,status IN_PROGRESS/SUCCESSFUL/FAILED) |
| retry | `PATCH /v1/tasks/{id}`(從失敗的 subtask 續跑) |

驗證(`/validations`)都是非同步:POST 拿 id → GET 到 `executionStatus=COMPLETED` 看 `resultStatus`。

## 這次踩的雷(詳見 `STRETCH-RUNBOOK.md`)
1. 移除主機卡 Enter Maintenance Mode → VCF 把 ESXi SSH 關了,開 TSM-SSH。
2. commission 驗證「vmk0 只能有 Management tag」→ 清掉 vMotion/vSAN tag。
3. Remediate ESXi `HealthCheckFailed` ×3:SDDC Manager 不講原因,要看 vCenter `vum-server.log`
   (`Overall vSAN cluster health is: red`)+ `vsan-health-summary-result.log`(哪一項紅)。
   真因:(a) VCF 套 PFTT=1/SFTT=1 全物件 resync + 容量不夠;(b) witness vmk MTU 1500 → largeping 紅。
