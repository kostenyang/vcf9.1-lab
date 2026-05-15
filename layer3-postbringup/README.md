# Layer 3 — Post bring-up

Bring-up 完之後的 SDDC Manager 動作: commission hosts / create workload domains / deploy NSX edges.

## 故障排除紀錄

- [vcf-operations-automation-deploy-troubleshooting.md](./vcf-operations-automation-deploy-troubleshooting.md)
  — M02「Install VCF Operations / Automation using Fleet Lifecycle」部署失敗的完整排錯：
  根因為 nested-on-nested vSAN 拖垮 VSP Supervisor etcd → Fleet LCM timeout → `RequestCanceled`；
  含修復步驟、除錯指令、用到的 script、各元件取得權限的技巧。(2026-05-14,部署最終
  `COMPLETED_WITH_SUCCESS`)

## 預計實作

- `Commission-Hosts.ps1` — 把多餘 ESXi 加進 SDDC Manager 的 host pool
- `New-WorkloadDomain.ps1` — 建第二個 workload domain
- `Deploy-NsxEdge.ps1` — 自動 deploy NSX edge cluster

## TODO

- [ ] SDDC Manager API auth helper (token cache)
- [ ] Host commissioning JSON
- [ ] Workload domain JSON
