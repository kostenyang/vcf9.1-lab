# sdk — VCF 9.1 開發用 API spec 與 SDK 指引

開發 VCF 9.1 自動化要用哪個 SDK、怎麼取得、怎麼產 client。

## 這個資料夾有什麼
| 檔 | 說明 |
|---|---|
| `vcf-installer-openapi.json` | **VCF Installer 9.1 OpenAPI 3.0 spec**(371KB,真實 schema:bring-up SddcSpec、depot、bundle、validation…)。從實機 installer 抽出 |

> 也可即時從 installer 撈最新 spec:`GET https://<installer>/v1/api-docs`(或 installer UI 的 Swagger)。SDDC Manager 起來後也有自己的 spec:`https://<sddc-manager>/v1/api-docs`。

## 要不要下載官方 SDK?
看你要開發什麼:

| 目標 | 建議方式 | 取得 |
|---|---|---|
| VCF Installer / SDDC Manager REST(bring-up、depot、bundle、domain、host…)| **用本資料夾的 OpenAPI spec 產 client**,或直接 `requests` | 已有 spec |
| vCenter 底層(VM/cluster/網路/SPBM…)| **pyVmomi** | `pip install pyvmomi` |
| vSphere 新版 REST/vAPI | vSphere Automation SDK | `github.com/vmware/vsphere-automation-sdk-python` |
| PowerShell 開發 VCF | **PowerCLI `VMware.Sdk.Vcf.*`** | `Install-Module VMware.PowerCLI` |
| 要官方 typed SDK(Java/Python)| Broadcom Developer Portal | https://developer.broadcom.com → VMware Cloud Foundation |

**結論**:nested-workarounds 那套(`requests` + `pyvmomi`)已涵蓋實務所需,**不必特地下大包 SDK**。要正式 typed client 時,用下面的 codegen 從本 spec 生成最乾淨。

## 用 OpenAPI spec 產 Python client(openapi-generator)
```bash
# 需 Java;或用 npx
npm install -g @openapitools/openapi-generator-cli   # 或 brew install openapi-generator

openapi-generator-cli generate \
  -i vcf-installer-openapi.json \
  -g python \
  -o ./vcf-installer-client-python \
  --additional-properties=packageName=vcf_installer_client

# 之後:
#   from vcf_installer_client import ApiClient, Configuration
#   from vcf_installer_client.api.sddcs_api import SddcsApi
```
其他語言把 `-g python` 換成 `java` / `go` / `typescript-axios` 等即可。

## 官方下載連結
- Broadcom Developer Portal(VCF API / SDK):https://developer.broadcom.com
- pyVmomi:https://github.com/vmware/pyvmomi (`pip install pyvmomi`)
- vSphere Automation SDK (Python):https://github.com/vmware/vsphere-automation-sdk-python
- PowerCLI(含 `VMware.Sdk.Vcf.*`):PowerShell Gallery `Install-Module VMware.PowerCLI`
- VCF download tool(抓 binaries/depot,非 SDK):Broadcom Support Portal

## 跟本 repo 的關係
- `nested-workarounds/python/` 已示範用 `requests`(REST)+ `pyvmomi`(vCenter)直接做事,不需 codegen。
- 想要 typed client / 給開發團隊正式用,再用上面 codegen 從 spec 生成。
