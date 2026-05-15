# Layer 2 — VCF 9.1 Installer Bring-up

把 VCF Installer 接到 4 台已升級到 9.1 的 nested ESXi，自動 bring up Management Domain (vCenter + NSX + SDDC Manager)。

## 三隻 PowerShell + 一份 template

| 檔案 | 角色 |
|---|---|
| `vcf91-bringup.template.json` | JSON template |
| `Generate-BringupSpec.ps1` | 渲染 template + sops 解密 secrets + 套用 lab workaround → generated-bringup.json |
| `Submit-Bringup.ps1` | 推到 VCF Installer API，先 validation 再 bring-up，poll 完成 |
| `New-VcfLab.ps1` | 一鍵 wrapper：產 spec → validate → 人類確認 → bring-up |

## 跑法

前提：
1. 4 台 nested ESXi 已升級到 9.1
2. `layer1-nested/Prepare-NestedESXi.ps1` 已跑過（advanced settings 套用完成）
3. VCF Installer appliance 已部署且可由執行機器連到
4. `inventory/lab.yaml` 填好
5. `inventory/secrets/lab.yaml` 用 sops 加密好（有 age 私鑰）

```powershell
cd layer2-bringup
pwsh ./New-VcfLab.ps1 -VcfInstaller https://<vcf-installer-ip-or-fqdn>
```

`Generate-BringupSpec.ps1` 會自己用 sops 解密 `inventory/secrets/lab.yaml`，不需要先 source 任何 env vars。

## Lab workarounds

`-LabMode`（預設開）在 spec 注入 skipChecks：
- `NESTED_CPU_CHECK`
- `NIC_COUNT_CHECK`
- `MIN_HOST_CHECK`
- `VSAN_ESA_HCL_CHECK`
- `ESX_THUMBPRINT_CHECK`

正式環境加 `-SkipLabMode`。

### domainmanager timeout 調整

慢速 lab 還需把 VCF Installer / SDDC Manager 的 `domainmanager` timeout 參數調大,
避免 appliance OVF 佈署 / 服務啟動超時導致 bring-up 失敗:

- [timeout-tuning.md](timeout-tuning.md) — 調整的參數、受影響主機、備份與回退
- [timeout-tuning-operations-log.md](timeout-tuning-operations-log.md) — 實際操作指令(含取得 root 的 pty + su 方法)

## 待補

- [ ] VCF 9.1 OpenAPI 對齊欄位名（nsxtSpec? nsxSpec?），跑 `-ValidateOnly` 看 error 對齊
- [ ] vCenter / NSX / SDDC Manager IP 拉進 inventory
- [ ] William Lam VCF 9.1 lab post 的 skipChecks 確切名稱對齊
- [ ] 多 workload domain → 拆到 layer3-postbringup/
