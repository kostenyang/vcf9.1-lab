# VCF 9.1 Lab — Installer / SDDC Manager Timeout 調整紀錄

調整日期:**2026-05-14**
參考來源:William Lam — [VCF 9.1 Comprehensive VCF Installer & SDDC Manager Configuration Workarounds for Lab Deployments](https://williamlam.com/2026/05/vcf-9-1-comprehensive-vcf-installer-sddc-manager-configuration-workarounds-for-lab-deployments.html)

## 目的

Lab 環境(nested ESXi、慢速 storage)部署 VCF 9.x 時,各 appliance 的 OVF 佈署 / 服務啟動經常超過預設逾時而導致 bring-up 失敗。
本紀錄將 **VCF Installer** 與 **SDDC Manager** 上 `domainmanager` 服務的 timeout 參數調大,降低 lab 部署失敗率。屬於 layer2-bringup 的 lab workaround 之一。

## 受影響主機

| 角色 | FQDN | IP | SSH 登入帳號 |
|---|---|---|---|
| VCF Installer (Cloud Builder) | vcf-m01-cb01.home.lab | 10.0.1.4 | `vcf` → `su - root` |
| SDDC Manager (M02) | vcf-m02-sddcm01.home.lab | 10.0.1.18 | `vcf` → `su - root` |

> 註:lab 內 DNS 無法解析這兩個 FQDN,實際以 IP 連線。
> 兩台皆不允許 root 直接 SSH;`vcf` 帳號 sudoers 只開放 `/opt/vmware/sddc-support/sos`,
> 因此改用 `vcf` 登入後以 pseudo-tty 執行 `su - root` 取得 root(詳見 [timeout-tuning-operations-log.md](timeout-tuning-operations-log.md))。

## 設定檔

兩台皆相同:

```
/etc/vmware/vcf/domainmanager/application.properties
```

擁有者 `vcf_domainmanager:vcf`,權限 `600`。修改後需重啟服務:

```
systemctl restart domainmanager
```

## 調整的參數

以下參數原本皆 **不存在** 於 `application.properties`(使用 jar 內建預設值),本次以覆寫方式新增:

| 參數 | 預設值 | 調整後 | 說明 |
|---|---|---|---|
| `nsxt.manager.wait.minutes` | (code default) | `180` | NSX Manager appliance 部署等待 |
| `edge.node.vm.creation.max.wait.minutes` | (code default) | `90` | NSX Edge VM 建立等待 |
| `vsp.bootstrap.task.timeout.minutes` | (code default) | `240` | VCF 管理服務 (vSphere Supervisor) bootstrap task |
| `vsp.bootstrap.command.timeout.minutes` | (code default) | `200` | VCF 管理服務 bootstrap command |
| `nsxt.alb.image.upload.retry.check.interval.seconds` | `10` | `90` | Avi Load Balancer OVA 上傳 retry 間隔 |
| `vc.appliance.services.check.timeout.minutes` | `30` | `240` | vCenter appliance OVF 佈署後服務啟動檢查逾時 |

### 關於 "OVF deploy timeout"

VCF **沒有** 單一通用的 OVF/OVA 佈署逾時參數。各 appliance(vCenter / NSX / SDDC Manager / Edge / Avi)的 OVF 佈署是由上表「各元件各自的等待參數」控制。
其中 `vc.appliance.services.check.timeout.minutes` 是最接近「appliance 佈署後等待」的參數,本次一併調大。

## 最終狀態

兩台 `application.properties` 結尾皆包含:

```properties

# VCF 9.1 lab timeout workarounds (williamlam.com)
nsxt.manager.wait.minutes=180
edge.node.vm.creation.max.wait.minutes=90
vsp.bootstrap.task.timeout.minutes=240
vsp.bootstrap.command.timeout.minutes=200
nsxt.alb.image.upload.retry.check.interval.seconds=90
vc.appliance.services.check.timeout.minutes=240
```

重啟後 `systemctl is-active domainmanager` → `active`(兩台)。

## 備份

每次修改前都先 `cp -p` 備份原檔,位於同目錄下:

| 主機 | 第一批(5 參數)備份 | 第二批(vc.appliance...)備份 |
|---|---|---|
| VCF Installer 10.0.1.4 | `application.properties.bak-20260514-055017` | `application.properties.bak-20260514-055407` |
| SDDC Manager 10.0.1.18 | `application.properties.bak-20260514-054923` | `application.properties.bak-20260514-055428` |

回退方式:`cp -p <備份檔> /etc/vmware/vcf/domainmanager/application.properties` 後重啟 `domainmanager`。

## 安全性備註

- 本文件 **不包含任何明文密碼**。root / vcf 密碼請另存於密碼管理工具(repo 內 `inventory/secrets/` 以 sops 加密)。
- 部署完成後建議輪換本次作業中使用過的帳號密碼。
