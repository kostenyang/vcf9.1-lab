# vSAN Cluster Partition 除錯流程

VCF 9 nested lab，bring-up 中斷後發現 vSAN 4 台 host 各自一個 partition、CMMDS 沒有 master、vSAN datastore 不可用。本文件記錄完整的診斷與修復流程。

## 環境

| 項目 | 值 |
|---|---|
| 外層 vCenter | labvc.lab.com |
| Nested vCenter | vcf-m02-vc01.home.lab |
| Cluster | vcf-m02-cl01 (4 台 nested ESXi) |
| Hosts | vcf-m02-esx01~04 / 10.0.1.14~17 |
| vSAN VMK | vmk2 / 192.168.14.0/24 (VLAN 4) |
| 底層 PG | Trunk-Nobinding (VLAN trunk 0-4094) |
| VCF / ESXi 版本 | VCF 9.1 / ESXi 9.x |

## 問題現象

- vSAN cluster health：每台 host `Sub-Cluster Member Count = 1`
- vSphere UI：`No vSAN Master found in the cluster`、`vSAN datastore inaccessible`
- VCF Installer VM `vcf-m02-inst01` 為 **PoweredOff** → bring-up 未完成
- 4 台 host 的 vSAN cluster UUID **相同** (`52961dc1-...`)，但 partition 數 = 4

## 診斷流程

### Step 1 — 先看 cluster health (PowerCLI)

```powershell
Connect-VIServer vcf-m02-vc01.home.lab `
    -User administrator@vsphere.local -Password '<pwd>'

$cluster = Get-Cluster -Name vcf-m02-cl01
$vchs    = Get-VsanView -Id 'VsanVcClusterHealthSystem-vsan-cluster-health-system'
$health  = $vchs.VsanQueryVcClusterHealthSummary($cluster.ExtensionData.MoRef,
                                                  $null, $null, $true, $null, $false, 'defaultView')

$health.ClusterStatus.TrackedHostsStatus |
    Format-Table Hostname, Status, Issues -AutoSize
```

每台 host 顯示 **red**、`Issues = Network`。

### Step 2 — 進一步看每台 host 的 CMMDS 成員

SSH 進每台 ESXi 跑：

```bash
esxcli vsan cluster get
```

關鍵欄位：

```
Sub-Cluster Member Count: 1                # 應該是 4
Sub-Cluster Member UUIDs: <only myself>
Unicast Mode Enabled: true                 # ESXi 9.x 預設 unicast
```

**4 台都只看到自己** → vSAN control plane 互相看不到對方。

### Step 3 — 檢查 unicast agent list（關鍵）

```bash
esxcli vsan cluster unicastagent list
```

**每台 host 結果都是空的**。這就是直接原因。

> ESXi 9.x 預設用 unicast CMMDS（不再用 multicast）。vCenter 在 vSAN cluster 建立時要把 peer 清單推給每台 host；如果 bring-up 中斷，這個清單可能沒推完 → 互相看不到。

### Step 4 — 排除底層網路嫌疑（紅鯡魚，但要走過）

#### 4a. Trunk-Nobinding 安全策略

在外層 vCenter：

```powershell
Connect-VIServer labvc.lab.com -User administrator@vsphere.local -Password 'VMware1!'

$pg = Get-VDPortgroup -Name 'Trunk-Nobinding'
Get-VDSecurityPolicy -VDPortgroup $pg |
    Format-List AllowPromiscuous, MacChanges, ForgedTransmits
```

- `MacChanges = True`、`ForgedTransmits = True` ✅
- `AllowPromiscuous = False` → 啟用：

```powershell
Get-VDSecurityPolicy -VDPortgroup $pg |
    Set-VDSecurityPolicy -AllowPromiscuous $true
```

VLAN trunk 0-4094 已設定。

#### 4b. nested VM 是否有 dvfilter-maclearn

```powershell
$vms = Get-VM -Name vcf-m02-esx0*
foreach ($vm in $vms) {
    $vm.ExtensionData.Config.ExtraConfig |
        Where-Object Key -like 'ethernet*.filter*' |
        Select-Object @{n='VM';e={$vm.Name}}, Key, Value
}
```

每個 NIC 都有 `dvfilter-maclearn` ✅

**等 3 分鐘後再看 partition 沒變** → 不是 multicast / mac learning 問題。回到 unicast 路線。

### Step 5 — 確認 root cause = unicast peer list 空

```bash
# 每台 host：
esxcli vsan cluster get             # 確認 Unicast Mode Enabled = true
esxcli vsan cluster unicastagent list  # 空 = bingo
```

## 根因

VCF Installer (`vcf-m02-inst01`) 在 bring-up 中途被關機，vCenter 沒把 vSAN unicast peer 清單推給 4 台 host。

ESXi 9.x 預設 unicast CMMDS，沒有 peer 清單就互相看不到，每台變成自己一個 partition。

## 修復

對每台 host，把**其他 3 台**加成 unicast peer。

### 蒐集每台的 Node UUID + vSAN VMK IP

```bash
# 每台跑（也可一次列出）
esxcli vsan cluster get | grep 'Local Node UUID'
esxcli network ip interface ipv4 get -i vmk2
```

範例蒐集結果：

| Host | Mgmt IP | vSAN IP (vmk2) | Node UUID |
|---|---|---|---|
| esx01 | 10.0.1.14 | 192.168.14.5 | `6a042045-...-44ba` |
| esx02 | 10.0.1.15 | 192.168.14.6 | `8b15a132-...-5acb` |
| esx03 | 10.0.1.16 | 192.168.14.7 | `9c26b243-...-6bdc` |
| esx04 | 10.0.1.17 | 192.168.14.8 | `0d37c354-...-7ced` |

### 加 peer（每台跑 3 次）

```bash
# 在 esx01 (10.0.1.14) 加 esx02 / esx03 / esx04
esxcli vsan cluster unicastagent add \
  -a 192.168.14.6 -u <esx02-uuid> -t node -U true

esxcli vsan cluster unicastagent add \
  -a 192.168.14.7 -u <esx03-uuid> -t node -U true

esxcli vsan cluster unicastagent add \
  -a 192.168.14.8 -u <esx04-uuid> -t node -U true
```

參數說明：

| Flag | 意義 |
|---|---|
| `-a` | peer 的 vSAN VMK IP（**不是** mgmt IP） |
| `-u` | peer 的 Local Node UUID |
| `-t node` | type = node（**不是預設的 witness**） |
| `-U true` | supports-unicast = true |

`-t node -U true` 不能省，預設值會把它加成 witness、互通不起來。

PuTTY plink 範例（一次跑完所有 host）：

```powershell
$pwd = 'VMware1!VMware1!'
$peers = @{
  '10.0.1.14' = @(
    'esxcli vsan cluster unicastagent add -a 192.168.14.6 -u <esx02-uuid> -t node -U true'
    'esxcli vsan cluster unicastagent add -a 192.168.14.7 -u <esx03-uuid> -t node -U true'
    'esxcli vsan cluster unicastagent add -a 192.168.14.8 -u <esx04-uuid> -t node -U true'
  )
  # ... 其他 3 台同理
}
foreach ($h in $peers.Keys) {
  foreach ($cmd in $peers[$h]) {
    & 'C:\Program Files\PuTTY\plink.exe' -ssh -batch -pw $pwd "root@$h" $cmd
  }
}
```

> 第一次連會跳 host key 確認，先跑一個 `echo ok` 接受 fingerprint 再執行 add 即可。

## 驗證

```bash
esxcli vsan cluster get
```

期望：

```
Sub-Cluster Member Count: 4
Sub-Cluster Member UUIDs: <esx01-uuid>, <esx02-uuid>, <esx03-uuid>, <esx04-uuid>
```

PowerCLI 端：

```powershell
$health = $vchs.VsanQueryVcClusterHealthSummary( ... )   # 同 Step 1
$health.ClusterStatus.TrackedHostsStatus.Status          # 全部 green
```

實測收斂時間：**約 45 秒**。

剩餘 RED 項目（`vSAN object health`、`config consistency`、`vCenter state authoritative`）→ 都是 VCF bring-up 沒完成造成的，不是 partition 問題。

## 預防 / 自動化

### Nested ESXi vSAN advanced settings（必跑）

nested 環境跟 physical 不一樣：底層磁碟是另一個 vSAN 的虛擬磁碟、CPU 被擠壓、SCSI reservation 不會真的 lock 到實體硬碟。如果不關掉相關檢查 / 開啟 fake 機制，nested vSAN 會誤判錯誤、效能很差、甚至根本起不來。

| Setting | 值 | 為什麼 nested 要動 |
|---|---|---|
| `/LSOM/VSANDeviceMonitoring` | 0 | 關閉 device monitoring。nested 的「磁碟」其實是 vmdk，IO latency / error pattern 跟真硬碟不同，開著會被誤判成壞碟 |
| `/LSOM/lsomSlowDeviceUnmount` | 0 | 關閉慢速磁碟自動 unmount。nested 虛擬磁碟天生慢，會被當成壞碟踢掉 |
| `/VSAN/SwapThickProvisionDisabled` | 1 | 停用 swap thick provision。nested 不需要也沒空間 thick 預配 swap |
| `/VSAN/Vsan2ZdomCompZstd` | 0 | 回退到 LZ4 壓縮。nested CPU 通常被 over-commit，Zstd 太重會卡住 |
| `/VSAN/FakeSCSIReservations` | 1 | **關鍵**。nested vSAN 跑在 physical vSAN 上時，SCSI reservation 沒辦法穿透；不開這個 nested vSAN 拿不到 lock 就起不來 |
| `/VSAN/GuestUnmap` | 1 | 讓 TRIM/UNMAP 從 guest → nested vSAN → physical vSAN 全程傳遞，省底層空間 |

### 跑法

```powershell
# Bring-up 前對 4 台 nested ESXi 套用上面 6 個 setting
pwsh layer1-nested/Prepare-NestedESXi.ps1

# 只看現值不修改
pwsh layer1-nested/Prepare-NestedESXi.ps1 -DryRun
```

詳見 [`layer1-nested/Prepare-NestedESXi.ps1`](../layer1-nested/Prepare-NestedESXi.ps1)。

### 跟本次 partition 問題的關係

這 6 個 advanced settings **跟這次的 unicast partition 不是同一個問題**：

- partition = VCF bring-up 中斷沒推 unicast peer list（control plane 看不到對方）
- advanced settings = 即使 control plane 通了，nested 的 vSAN data path 也需要這些開關才能正常運作（data path 不會起來、或起來後一直噴 error）

兩個都是 nested 的關係，但走的層次不同。lab 部署兩個都要做才完整：

1. **layer1-nested/Prepare-NestedESXi.ps1** — 開機後馬上跑（這 6 個 setting）
2. **VCF Installer bring-up** — 中途不要中斷，讓它把 unicast peer list 推完
3. 萬一還是發生 partition → 跑本文件的 [修復](#修復) 步驟手動補 peer

## 指令快速查表

```bash
# 看 vSAN cluster 狀態
esxcli vsan cluster get

# 看 unicast peer 清單
esxcli vsan cluster unicastagent list

# 加 unicast peer
esxcli vsan cluster unicastagent add -a <peer-vsan-ip> -u <peer-uuid> -t node -U true

# 移掉 peer（用 UUID）
esxcli vsan cluster unicastagent remove -u <peer-uuid>

# 看 vSAN VMK
esxcli network ip interface ipv4 get -i vmk2

# 看 advanced setting
esxcli system settings advanced list -o /VSAN/FakeSCSIReservations
```

```powershell
# vSAN health 一覽
$vchs = Get-VsanView -Id 'VsanVcClusterHealthSystem-vsan-cluster-health-system'
$vchs.VsanQueryVcClusterHealthSummary(
    (Get-Cluster vcf-m02-cl01).ExtensionData.MoRef,
    $null, $null, $true, $null, $false, 'defaultView'
).ClusterStatus.TrackedHostsStatus | Format-Table -AutoSize
```

## 參考

- William Lam — [VCF 9.1 comprehensive ESX configuration workarounds for lab deployments](https://williamlam.com/2026/05/vcf-9-1-comprehensive-esx-configuration-workarounds-for-lab-deployments.html)
- William Lam — [Enable TRIM/UNMAP from nested vSAN to physical vSAN](https://williamlam.com/2025/03/enable-trim-unmap-from-nested-vsan-osa-esa-to-physical-vsan-osa.html)
