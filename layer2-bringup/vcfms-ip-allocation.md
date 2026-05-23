# VCF 9.1 — VCFMS IP Allocation Options

VCF 9.1 起,VCF Management Services(VCFMS)的 IP 配置有三種模式可選,解決舊版必須給「連續 IP 段」(VCF Installer)或「整塊 CIDR」(SDDC Manager)而在 IP 受限環境下浪費或無法部署的問題。

**參考來源**:William Lam — [VCF 9.1 Additional IP Allocation Options for VCF Management Services (VCFMS) in VCF Installer and SDDC Manager](https://williamlam.com/2026/05/vcf-9-1-additional-ip-allocation-options-for-vcf-management-services-vcfms-in-vcf-installer-and-sddc-manager.html)

## 適用範圍

| 工具 | 入口 |
|---|---|
| **VCF Installer** | bring-up JSON 內的 `vspClusterSpec.ipv4Pool.ipRange` 區塊 |
| **SDDC Manager**(部署完成後 / 升級流程) | `POST /vcf-management-components` API,body 用同一個 `vspClusterSpec` 結構 |

⚠️ **最小 12 個 IP** —— 三種模式都至少要 12 個可用 IP;CIDR 最小用到 `/28`(14 個可用,比下限多 2)。

## 模式 1 — IP Range(起訖 + 排除清單)

最直覺,給起點與終點;`excludeAddresses` 可挑某幾個跳過。

```json
"vspClusterSpec": {
  "ipv4Pool": {
    "ipRange": {
      "startIpAddress": "172.30.0.145",
      "endIpAddress": "172.30.0.158",
      "excludeAddresses": ["172.30.0.144", "172.30.0.145"]
    }
  }
}
```

## 模式 2 — CIDR(整塊網段 + 排除清單)

給一塊 CIDR,要把廣播 / 網路 / 已用的 IP 排掉時用 `excludeAddresses`。

```json
"vspClusterSpec": {
  "ipv4Pool": {
    "ipRange": {
      "cidr": "172.30.0.144/28",
      "excludeAddresses": ["172.30.0.157", "172.30.0.158"]
    }
  }
}
```

> 注意:原 William Lam blog 的 CIDR 範例呈現為 `"http://172.30.0.144/28"`,那是 markdown 自動加超連結的副作用,**真實 JSON 值不含 `http://`**,只放純 CIDR 字串。

## 模式 3 — 完整列出 IP(離散名單)

對「我手上能用的 IP 不連續、且懶得算 exclude」的情境最方便。

```json
"vspClusterSpec": {
  "ipv4Pool": {
    "ipRange": {
      "addresses": [
        "172.30.0.144",
        "172.30.0.146",
        "172.30.0.148",
        "172.30.0.150",
        "172.30.0.152",
        "172.30.0.154",
        "172.30.0.156",
        "172.30.0.158",
        "172.30.0.160",
        "172.30.0.162",
        "172.30.0.163",
        "172.30.0.164"
      ]
    }
  }
}
```

## 三種模式怎麼選

| 你手上的 IP | 建議 |
|---|---|
| 一段連續、頭尾乾淨 | **IP Range**(`startIpAddress` / `endIpAddress`) |
| 一塊完整網段,只有少數要避開 | **CIDR** + `excludeAddresses` |
| 不連續、來自不同子網段的湊出 12 個 | **explicit `addresses` 列表** |

## 與本 repo 的關係

- **Bring-up 階段**:把上面其中一種 `vspClusterSpec.ipv4Pool.ipRange` 區塊塞進 [vcf91-bringup.template.json](./vcf91-bringup.template.json) 的對應位置(請以 `-ValidateOnly` 走過一次 [Submit-Bringup.ps1](./Submit-Bringup.ps1) 確認 9.1 OpenAPI schema 接受)。
- **Post-bringup 升級 / 重配**:對 SDDC Manager 打 `POST /vcf-management-components`,body 用同一個結構(可透過 `mcp-server` 的 `sddc_manager_api` tool 呼叫,見 [github.com/kostenyang/mcp](https://github.com/kostenyang/mcp))。
- 本 lab(M02)的 VCFMS IP 規劃見 [../inventory/lab.yaml](../inventory/lab.yaml)。
