# 安全關機 VCF Services Runtime Cluster

> 計畫性停機(維運、機房斷電、冷備份、退役)時把整個 **VCF Services Runtime Cluster**
> (Fleet + Instance,跑著 VCF Management Components)按依賴順序乾淨停下來的官方流程。
>
> **參考來源**:Broadcom KB 440874 — [How to safely shutdown all nodes within a VCF Services Runtime Cluster](https://knowledge.broadcom.com/external/article/440874/how-to-safely-shutdown-all-nodes-within.html)

## 適用範圍

| 項目 | 內容 |
|---|---|
| VCF 版本 | VCF Management Services Runtime 9.1.0.0 / VCF Automation 9.1.0.0 |
| 目標 | Fleet + Instance Cluster(VSP Supervisor 上的 VCF MS Runtime)整個關機 |
| **不適用** | 單台 worker 節點(那是另一支流程) |

⚠️ **執行前知會所有相關系統與使用者** —— 這支腳本會把所有 VCF management components 停掉,包含 **Log Management、Realtime Metrics、VCF Operations Lifecycle、Configuration Management**。

## 何時用

- 計畫性基礎建設維運
- 機房斷電前的優雅關機
- 冷備份 / VM snapshot 前
- 整個部署退役

## 前置

1. 一台跑腳本的機器(能連到 VSP Supervisor 控制節點 port 5480 即可)
2. 工具:`curl`、`jq`、`govc`
3. 下載 KB 提供的腳本 `vcf_services_runtime_shutdown.sh`(自 KB 440874 下載),`chmod +x` 後備用
4. 取得 **VSP Supervisor 控制節點 IP** —— 在 VCF Operations UI:`Build → Lifecycle → Components → VCF Services Runtime → Nodes`
5. SSH 進控制節點拿 kubeconfig:
   ```bash
   ssh vmware-system-user@<control-plane-ip>
   sudo -i
   cp /etc/kubernetes/admin.conf /local/path/kubeconfig
   ```

> **本 lab(M02)實測**:VSP Supervisor 控制節點 IP = `10.0.0.222`(其他 supervisor 節點的 admin.conf 是空的;`10.0.0.243` 是 VCF Automation appliance 自己的 K8s 節點,不是這支腳本的目標)。控制節點 root 密碼會被 WCP 定期輪替,失效時用 vCenter 上的 `/usr/lib/vmware/wcp/decryptK8Pwd.py` 取回。

## 三種執行模式

### Mode A — Dry Run(**強烈建議先跑這個**)

不做任何破壞,只列計畫:

```bash
./vcf_services_runtime_shutdown.sh \
  --node-ip <NODE_IP> \
  --dry-run \
  --kubeconfig <kubeconfig-file>
```

### Mode B — 只關服務,**不關 VM**(VM 留著)

```bash
./vcf_services_runtime_shutdown.sh \
  --node-ip <NODE_IP> \
  --skip-poweroff \
  --kubeconfig <kubeconfig-file>
```

### Mode C — 完整關機(服務 + VM 一起 power off)

```bash
export VCENTER_USER=<username>
export VCENTER_PASSWORD=<password>

# 自動探查 vCenter 不到時手動指定
# export GOVC_URL=https://<vcenter-address>

./vcf_services_runtime_shutdown.sh \
  --node-ip <NODE_IP> \
  --kubeconfig <kubeconfig-file>
```

## 腳本會幫你做的事

- 內部依賴順序排程(automatic dependency ordering)
- Pre-check(含**偵測有沒有 snapshot**)
- 優雅 scale down workloads
- 設旗標確保開機後可自動 recovery

## 即時 log 監看

```bash
./vcf_services_runtime_shutdown.sh ... 2>&1 | \
  tee /tmp/vcf_shutdown_$(date +%Y%m%d_%H%M%S).log
```

跑成功時會看到像 `Task task-456 status: Succeeded` 的逐筆 log。

## 開機 / 復原

⚠️ **KB 440874 沒有寫**對應的 power-on 步驟,只提到「腳本會設旗標讓開機自動 recovery」。
實際 power-on 的順序、需要的等待時間、verification 都在這份 KB 之外,本 lab 還沒實測過。
等實測過再回頭補本節。

## 注意事項

- 動工前**通知所有依賴 VCF management components 的系統與使用者**
- vCenter 帳密只有 Mode C 需要(用來 power off VM)
- 確認**沒有失敗中或進行中的 workflow** 再跑(同 KB 對應的 Fleet Management 一般前提)

## 與 lab 其他文件的關連

- [k8s-access-and-checks.md](../layer3-postbringup/k8s-access-and-checks.md) — VSP Supervisor 控制節點 SSH / kubeconfig 取得方式
- [vcf-operations-automation-deploy-troubleshooting.md](../layer3-postbringup/vcf-operations-automation-deploy-troubleshooting.md) — 同樣的 VSP Supervisor 在部署排錯時怎麼進去
