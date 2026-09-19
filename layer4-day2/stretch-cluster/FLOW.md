# Stretch 整個流程(一頁版)

一句話:**減一台 → 加三台 commission → witness(MTU 9000)→ validate → PATCH stretch → policy 改 SFTT=0 → 等 resync / health 綠 → retry → 驗證**。

前提:mgmt domain bring-up 完成(4 台 nested ESXi,cluster `vcf-m01-cl01`)。
shell 版把 `python vcf_stretch.py X --cluster ...` 換成 `./vcf_stretch.sh X vcf-m01-cl01 ...` 就一樣。

## 0. 連線設定(跳板機或 Windows)

```bash
export SDDC_HOST=192.168.120.4 SDDC_USER=administrator@vsphere.local SDDC_PASS='...'
python vcf_stretch.py clusters && python vcf_stretch.py hosts && python vcf_stretch.py pools
```

## A. 兩邊主機數要相等 → 4 台變 3 台

- 先到 vCenter 把 esx04 的 SSH(TSM-SSH)開起來,不然卡在 Enter Maintenance Mode

```bash
python vcf_stretch.py remove-host --cluster vcf-m01-cl01 --host esx04.alan.lab --decommission
```

API:`POST /v1/clusters/{id}/validations` → `PATCH /v1/clusters/{id}`(clusterCompactionSpec)→ `DELETE /v1/hosts`

## B. 準備 AZ2 三台 + witness(API 之外的手工)

- DNS(dnsmasq 110.85)加 esx05-07、esx-witness
- OVA 部署 nested ESXi:AZ2 24 vCPU / 48GB,witness 4 vCPU / 16GB
- 套 6 個 vSAN nested advanced settings;SSH 開 + policy on
- vmk0 只留 Management tag(拿掉 vMotion / vSAN)

## C. Commission AZ2

```bash
python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password '...' --validate-only
python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password '...'
```

API:`POST /v1/hosts/validations` → `POST /v1/hosts`(thumbprint SHA-1)→ 狀態 UNASSIGNED_USEABLE

## D. Witness

```bash
python witness_prep.py --vc 192.168.120.3 --vc-pass '...' --dc vcf-m01-dc01 \
    --witness esx-witness.alan.lab --witness-pass '...' --vlan 140 --ip 192.168.140.68
```

加進 vCenter 當 standalone host(叢集外)+ vmk1 VLAN 140 **MTU 9000** + vsan tag
→ witness 上 `vmkping -I vmk1 -s 8972 -d 192.168.140.5~10` 全通才往下

## E. Stretch

```bash
python vcf_stretch.py gen-stretch-spec --cluster vcf-m01-cl01 --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab \
    --witness esx-witness.alan.lab --witness-ip 192.168.140.68 --witness-cidr 192.168.140.0/24 --overlay-vlan 150
python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --validate-only
python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --watch
```

API:`POST /v1/clusters/{id}/validations` → `PATCH /v1/clusters/{id}`(clusterStretchSpec)→ task 114 個 subtask,約 30 分

## F. 容量不夠 4 份時(nested 幾乎一定會)

task 跑過「Update vSAN Storage Profile」之後:

```bash
python vsan_policy_sftt0.py --vc 192.168.120.3 --vc-pass '...' --policy 'vcf-m01-cl01 vSAN Storage Policy'
```

PFTT=1/SFTT=1 → PFTT=1/SFTT=0,reapply 到全部 VM

## G. 掛在「Remediate ESXi Host(s)」HealthCheckFailed 時

1. 看 vCenter `/var/log/vmware/vmware-updatemgr/vum-server/vmware-vum-server.log`:`Overall vSAN cluster health is: red`
2. 看 `/var/log/vmware/vsan-health/vmware-vsan-health-summary-result.log`:哪一項紅(這次是 largeping = witness MTU)
3. 修掉 → `esxcli vsan debug resync summary get` 歸零 → Skyline Health 綠

```bash
python vcf_stretch.py retry <taskId>
```

## H. 驗證

```bash
python vcf_stretch.py clusters          # stretched=True
```

vCenter → Configure → vSAN → Fault Domains:Stretched cluster、witness、primary / secondary 各 3 台;`esxcli vsan cluster get` 7 members。

詳細每一步的 API body、失敗紀錄與 log 摘錄見 `STRETCH-RUNBOOK.md`;腳本說明見 `README.md`。
