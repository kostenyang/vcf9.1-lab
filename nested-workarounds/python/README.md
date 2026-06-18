# nested-workarounds (Python 版)

PowerShell 版(上層目錄)的 Python 對應版,給用 Python 的客戶。每支一件事、argparse 帶參數,
預設值對齊本環境(home.lab / 10.0.0.101 / 10.0.1.x / VMware1!),客戶換環境就帶參數。

> PowerShell 版是**已實機驗證**的;這個 Python 版是對應移植,建議在你環境先驗證
> (尤其 `set_vsan_ftt0.py` 用 pbm/SPBM API,最容易因版本差異要微調)。

## 需要的 SDK
| 套件 | 用途 |
|---|---|
| **pyvmomi** | vSphere API — vCenter 操作(network rollback、HA admission、reservation、dvPortgroup security、SPBM/FTT)|
| **requests** | VCF Installer REST API(depot、bring-up 監控)|

- Python **3.8+**
- 安裝:`pip install -r requirements.txt`(或 `pip install pyvmomi requests`)
- 建議用虛擬環境:`python -m venv venv && source venv/bin/activate`(Windows:`venv\Scripts\activate`)

## 怎麼跑
```bash
pip install -r requirements.txt

# 只需 requests 的(REST):
python connect_offline_depot.py --installer-ip 10.0.1.4 --depot-url http://10.0.0.61:8888
python watch_bringup.py        --installer-ip 10.0.1.4

# 需要 pyvmomi 的(vCenter):
python reset_trunk_promiscuous.py   --outer-vc 10.0.0.101 --portgroup Trunk-Nobinding
python disable_network_rollback.py  --vc 10.0.1.19
python disable_ha_admission_control.py --vc 10.0.1.19
python set_nested_reservations.py   --outer-vc 10.0.0.101 --vm-glob "vcf-m02-esx0*-91" --cpu-mhz 16000 --mem-gb 256
python set_vsan_ftt0.py             --vc 10.0.1.19 --reapply-existing

# 每支都有 -h / --help
python disable_network_rollback.py --help
```

## 對照表(Python ↔ PowerShell)
| Python | PowerShell | SDK |
|---|---|---|
| `connect_offline_depot.py` | `Connect-OfflineDepot.ps1` | requests |
| `watch_bringup.py` | `Watch-Bringup.ps1` | requests |
| `reset_trunk_promiscuous.py` | `Reset-TrunkPromiscuous.ps1` | pyvmomi |
| `disable_network_rollback.py` | `Disable-NetworkRollback.ps1` | pyvmomi |
| `disable_ha_admission_control.py` | `Disable-HaAdmissionControl.ps1` | pyvmomi |
| `set_nested_reservations.py` | `Set-NestedReservations.ps1` | pyvmomi |
| `set_vsan_ftt0.py` | `Set-VsanFtt0.ps1` | pyvmomi(pbm)|

用途/時機/VSP 卡住處理順序同上層 `../README.md`。
