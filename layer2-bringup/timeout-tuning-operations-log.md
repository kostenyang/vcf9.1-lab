# 操作指令紀錄 — VCF Timeout 調整 (2026-05-14)

實際對 VCF Installer (10.0.1.4) 與 SDDC Manager (10.0.1.18) 執行的指令。
密碼以 `<...>` 佔位符表示,實際值請參考 `inventory/secrets/`(sops 加密)或密碼管理工具。
搭配 [timeout-tuning.md](timeout-tuning.md) 一起看。

## 0. 前置:取得 root 的方式

兩台 appliance:
- root **不可** 直接 SSH。
- `vcf` 帳號可 SSH,但 `sudo -l` 僅允許 `/opt/vmware/sddc-support/sos`,無法用 sudo 編輯檔案。
- `su -` 需要 controlling terminal,非互動 SSH 會報 `su: must be run from a terminal`。

解法:以 `vcf` 登入後,用 `script` 建立 pseudo-tty 執行 `su - root`,並延遲 2 秒餵入 root 密碼避免 race condition:

```bash
(sleep 2; echo '<root-password>') | script -qec "su - root -c '<command>'" /dev/null
```

## 1. 確認來源(William Lam blog)的參數

從文章取得的 timeout 參數(皆套用於 VCF Installer 與 SDDC Manager,檔案
`/etc/vmware/vcf/domainmanager/application.properties`,改完 `systemctl restart domainmanager`):

- `nsxt.manager.wait.minutes = 180`
- `edge.node.vm.creation.max.wait.minutes = 90`
- `vsp.bootstrap.task.timeout.minutes = 240`
- `vsp.bootstrap.command.timeout.minutes = 200`
- `nsxt.alb.image.upload.retry.check.interval.seconds = 90`

## 2. 確認主機與設定檔現況

以 `vcf` 登入,執行 inspect script(透過上述 pty + su)。確認:
- 檔案存在,`-rw------- vcf_domainmanager:vcf`
- 上述 5 個參數皆不存在(使用 code 內建預設)
- `domainmanager` 服務 `active`

## 3. 套用第一批(5 個參數)

對 **10.0.1.4** 與 **10.0.1.18** 各執行下列 `apply` script(以 `vcf` 登入,
script 寫到 `/tmp/vcf_apply.sh` 後透過 pty + su 以 root 執行):

```bash
#!/bin/bash
set -e
F=/etc/vmware/vcf/domainmanager/application.properties
MARKER="# VCF 9.1 lab timeout workarounds (williamlam.com)"
TS=$(date +%Y%m%d-%H%M%S)
cp -p "$F" "$F.bak-$TS"                       # 備份
echo "Backup: $F.bak-$TS"
OWNER=$(stat -c '%U:%G' "$F"); MODE=$(stat -c '%a' "$F")
apply() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$F"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${val}|" "$F"
    echo "updated: ${key}=${val}"
  else
    echo "${key}=${val}" >> "$F"
    echo "added:   ${key}=${val}"
  fi
}
grep -qF "$MARKER" "$F" || { printf '\n%s\n' "$MARKER" >> "$F"; }
apply nsxt.manager.wait.minutes 180
apply edge.node.vm.creation.max.wait.minutes 90
apply vsp.bootstrap.task.timeout.minutes 240
apply vsp.bootstrap.command.timeout.minutes 200
apply nsxt.alb.image.upload.retry.check.interval.seconds 90
chown "$OWNER" "$F"; chmod "$MODE" "$F"       # 還原擁有者/權限
grep -nE 'nsxt\.manager\.wait\.minutes|edge\.node\.vm\.creation\.max\.wait\.minutes|vsp\.bootstrap\.|nsxt\.alb\.image\.upload\.retry' "$F"
ls -l "$F"
systemctl restart domainmanager
sleep 6
systemctl is-active domainmanager
```

執行方式:

```bash
# 在 vcf shell 中,script 已寫到 /tmp/vcf_apply.sh
(sleep 2; echo '<root-password>') | script -qec "su - root -c 'bash /tmp/vcf_apply.sh'" /dev/null
```

結果:5 個參數皆 `added`,`domainmanager` 重啟後 `active`。
備份:
- 10.0.1.4 → `application.properties.bak-20260514-055017`
- 10.0.1.18 → `application.properties.bak-20260514-054923`

## 4. 調查是否有獨立的 OVF deploy timeout

掃描 `domainmanager` 的 jar 內建設定確認沒有通用 OVF timeout:

```bash
JAR=/opt/vmware/vcf/domainmanager/vcf-domain-manager.jar
# 用 python3 zipfile 掃 BOOT-INF/classes/application*.properties 及 BOOT-INF/lib/*.jar
# 搜尋 key 含 ovf|ova|deploy|timeout|wait|retry 且值含數字者
```

結論:無 `ovf.deploy.timeout` 類參數;最接近者為
`vc.appliance.services.check.timeout.minutes`(jar 預設 `30`)。

## 5. 套用第二批(vc.appliance.services.check.timeout.minutes = 240)

對 **10.0.1.4** 與 **10.0.1.18** 各執行 `/tmp/vcf_apply2.sh`(同樣 pty + su 以 root 執行):

```bash
#!/bin/bash
set -e
F=/etc/vmware/vcf/domainmanager/application.properties
TS=$(date +%Y%m%d-%H%M%S)
cp -p "$F" "$F.bak-$TS"
echo "Backup: $F.bak-$TS"
OWNER=$(stat -c '%U:%G' "$F"); MODE=$(stat -c '%a' "$F")
key=vc.appliance.services.check.timeout.minutes; val=240
if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$F"; then
  sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${val}|" "$F"; echo "updated: ${key}=${val}"
else
  echo "${key}=${val}" >> "$F"; echo "added:   ${key}=${val}"
fi
chown "$OWNER" "$F"; chmod "$MODE" "$F"
grep -nE 'nsxt\.manager\.wait\.minutes|edge\.node\.vm\.creation\.max\.wait\.minutes|vsp\.bootstrap\.|nsxt\.alb\.image\.upload\.retry|vc\.appliance\.services\.check\.timeout\.minutes' "$F"
ls -l "$F"
systemctl restart domainmanager
sleep 6
systemctl is-active domainmanager
```

結果:`vc.appliance.services.check.timeout.minutes=240` `added`,`domainmanager` 重啟後 `active`。
備份:
- 10.0.1.4 → `application.properties.bak-20260514-055407`
- 10.0.1.18 → `application.properties.bak-20260514-055428`

## 6. 驗證

兩台 `grep` 結果一致(第 20–25 行):

```
nsxt.manager.wait.minutes=180
edge.node.vm.creation.max.wait.minutes=90
vsp.bootstrap.task.timeout.minutes=240
vsp.bootstrap.command.timeout.minutes=200
nsxt.alb.image.upload.retry.check.interval.seconds=90
vc.appliance.services.check.timeout.minutes=240
```

`systemctl is-active domainmanager` → `active`(兩台)。
