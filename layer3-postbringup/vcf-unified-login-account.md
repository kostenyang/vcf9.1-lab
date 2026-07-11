# VCF 統一登入帳號(home.lab AD → 全環境 SSO)

> 目的:在 home.lab AD 建立一個 **VCF 專用管理帳號**,透過 VCF SSO(VIDB identity broker)
> 一組帳密登入整個 VCF 9.1 環境(vCenter / NSX / VCFA / VCF Operations)。
> 建立日期 2026-07-02。對應 SSO 設定見 [`vcf91-sso-identity`](../../../.claude 或 labinfo.md 之 VCF SSO 章節)。

---

## 1. 帳號資訊

| 項目 | 值 |
|---|---|
| 登入帳號(UPN) | **`vcfadmin@home.lab`** |
| sAMAccountName | `vcfadmin` |
| 顯示名稱 | VCF Admin |
| 密碼 | `VMware1!VMware1!`(lab 慣例;密碼永不過期)|
| 所在容器 | `CN=Users,DC=home,DC=lab` |
| 群組成員 | **Domain Admins**(→ 繼承 Administrators)|
| 狀態 | Enabled、`ValidateCredentials` 通過 ✅ |
| 建立方式 | 在 home.lab DC 上 PowerShell `New-ADUser`(以 home\administrator 執行)|

> 用途定位:這是**管理員等級**的統一登入帳號。若要給租戶/一般使用者,請另建帳號並指派較低權限角色。

---

## 2. 為什麼一組帳密能登入整個環境

已於 2026-07-02 設定 **VCF SSO**,把 fleet 認證統一收斂到 **VIDB identity broker**,再由 VIDB 上接 home.lab AD:

```
                         home.lab AD (DC 10.0.0.200)
                                  │  LDAP bind: svc-vidb
                                  ▼
                    VIDB  vcf-m02-vidb.home.lab (10.0.0.174)
                    OIDC issuer: /acs/t/CUSTOMER/   ← tenant「CUSTOMER」
             ┌───────────────┬───────────────┬────────────────┐
             ▼               ▼               ▼                ▼
          vCenter          NSX            VCFA          VCF Operations
      (OIDC, default)  (OIDC endpoint)  (原生 IdP)      (SSO 樞紐)
```

- vcfadmin 是 **Domain Admins** 成員;Domain Admins 這個群組已(隨「ALL groups + Sync Nested Groups」)同步進 VIDB。
- 因此 vcfadmin 一次登入,四個元件都用同一個 VIDB OIDC 驗證。

---

## 3. 各元件登入方式

| 元件 | URL | 帳號填法 | 目前可登入? |
|---|---|---|---|
| **vCenter** | `https://vcf-m02-vc01.home.lab/ui` | `vcfadmin@home.lab` | 需先指派 vCenter 權限(見 §4)|
| **NSX** | `https://vcf-m02-nsx01.home.lab` | `vcfadmin@home.lab` | ✅ 群組 `Domain Admins@home.lab` 已綁 **Enterprise Admin**(見 §4)|
| **VCFA** | `https://vcf-m02-auto-vip.home.lab/` | `vcfadmin`(tenant CUSTOMER)| 需指派 org/role |
| **VCF Operations** | `https://vcf-m02-ops01.home.lab/` | `vcfadmin@home.lab` | 需指派 VCF Role |

> ⚠ 登入畫面要選 **VCF SSO / home.lab** 這個 identity source(不是 local / vsphere.local)。

---

## 4. 角色指派(已完成)

「接上 SSO」只代表**認證**能過;要能實際操作,還要**指派角色**。已用 **VCF Roles**(fleet 層)一次指派:

| 指派 | 內容 | 狀態 |
|---|---|---|
| **VCF Roles** | 群組 **`Domain Admins` (home.lab) → `VCF Administrator`**,Scope=**Components with vcf-m02-vidb.home.lab**(涵蓋 vCenter/NSX/Ops),Never Expires | ✅ 完成(2026-07-02)|
| NSX(額外) | `remote_group` `Domain Admins@home.lab` → **Enterprise Admin**(API,id `35a158f4…`)| ✅ 完成 |

> 位置:VCF Operations > Manage > Fleet Management > Identity & Access > **VCF SSO Overview** > Configure VCF SSO > **Assign VCF Roles** > Groups 分頁 > 篩 Domain Admins > ASSIGN。
> vcfadmin 是 Domain Admins 成員,故繼承 VCF Administrator。角色「will take effect in the next authentication」。

---

## 5. 生效前提:VIDB 目錄同步(重要雷點!)

vcfadmin 是**新建**帳號 —— **VIDB 只認已同步進來的使用者,不會對任意 AD 帳號即時認證**。
新帳號在下次目錄同步前登入會得到 **「Authentication was unsuccessful」**(實測過)。

**解法**:手動觸發同步 —
`Configure VCF SSO > Configure Identity Provider > (step 2) Edit > Directory Information` →
directory `home-lab` 那列右側 **「Sync On Request」** 圖示 → 按下 → 等 **Sync in Progress → 完成**
(Synced Users 會 +1)。之後登入即成功。

---

## 6. 登入測試結果(✅ 已驗證)

實測流程(截圖已擷取):
1. vCenter `https://vcf-m02-vc01.home.lab/ui` 登出 admin → 登入頁 **Login Method = VCF SSO**。
2. 按 LOG IN → 轉到 **VIDB「Directory Login」**(`vcf-m02-vidb.home.lab/vidb/login?tenant=CUSTOMER`)。
3. 輸入 **`vcfadmin@home.lab` / `VMware1!VMware1!`**。
4. (第一次因未同步被拒 → 觸發 Sync On Request 後)**成功登入 vCenter**,擁有完整管理權限(看得到 1 Cluster / 4 Hosts / 14 VMs、ACTIONS 可用)。

→ 證明 **一個 AD 帳號 `vcfadmin@home.lab` 經 VCF SSO 登入整個環境**、且具 VCF Administrator 權限。

### 已擷取的圖
| 圖 | 內容 |
|---|---|
| 圖1 | VCF Roles:Domain Admins → **VCF Administrator**(Changes successful)|
| 圖2 | vCenter 登入頁 **Login Method = VCF SSO** |
| 圖3 | **VIDB Directory Login**(tenant CUSTOMER)|
| 圖4 | vcfadmin **登入成功後的 vCenter Summary** |
| 圖5 | Directory `home-lab` **Sync On Request**(同步觸發)|
| （補）| 環境總覽 VCF Installer(10.0.1.4)|

---

## 7. 備註 / 待辦

- ✅ AD 帳號 vcfadmin、VCF Roles 指派、VIDB 同步、vCenter 登入 —— 全數完成並驗證。
- NSX / VCF Operations / VCFA 同理可用同一帳密登入(同屬此 VCF SSO 域、Domain Admins 已具 VCF Administrator);可自行再各截一張。
- ⚠ 測試時在 lab 那台 Chrome 把 vCenter 登成了 vcfadmin;要換回原本 `administrator@vsphere.local` 直接登出再登入即可(vcfadmin 本身即管理員,留著也可用)。
