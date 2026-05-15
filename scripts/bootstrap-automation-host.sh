#!/usr/bin/env bash
# =============================================================================
#  VCF 9 Lab — Automation Host Bootstrap
#  Target  : 10.0.0.65 (Ubuntu / Debian)
#  Result  : 一台「control plane」可以跑 PowerCLI / Ansible / Terraform / pyvmomi
#            + Docker + sops/age 加密 secret + GitHub CLI 接 private repo
#  Re-runnable: 全部步驟都檢查現況, 已裝過就略過
# =============================================================================
set -euo pipefail

LAB_ROOT="${LAB_ROOT:-/opt/vcf-lab}"
LAB_USER="${LAB_USER:-$(logname 2>/dev/null || echo "${SUDO_USER:-root}")}"
LOG=/var/log/vcf-bootstrap.log

#---------- helpers ----------------------------------------------------------
say()   { printf "\033[1;36m[BOOTSTRAP]\033[0m %s\n" "$*" | tee -a "$LOG"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n"      "$*" | tee -a "$LOG" >&2; }
die()   { printf "\033[1;31m[FAIL]\033[0m %s\n"      "$*" | tee -a "$LOG" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        say "需要 sudo, 重新呼叫自己..."
        exec sudo -E bash "$0" "$@"
    fi
}

require_root "$@"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

say "目標使用者: $LAB_USER"
say "Lab 根目錄: $LAB_ROOT"
say "Log: $LOG"

#---------- 0. distro sanity check ------------------------------------------
. /etc/os-release || die "讀不到 /etc/os-release"
case "$ID" in
    ubuntu|debian) say "Distro = $PRETTY_NAME ✓" ;;
    *) die "這份 script 只支援 Ubuntu/Debian, 你跑的是 $ID" ;;
esac

export DEBIAN_FRONTEND=noninteractive

#---------- 1. 基礎套件 -----------------------------------------------------
say "[1/9] apt update + 基礎套件"
apt-get update -qq
apt-get install -y -qq \
    ca-certificates curl wget gnupg lsb-release software-properties-common \
    apt-transport-https git jq unzip zip make build-essential \
    python3 python3-pip python3-venv \
    openssh-client sshpass net-tools dnsutils iputils-ping

# yq (Go 版本, mikefarah)
if ! have yq; then
    say "  -> 裝 yq"
    YQ_VER=$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r .tag_name)
    wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_amd64"
    chmod +x /usr/local/bin/yq
fi

#---------- 2. PowerShell 7 + PowerCLI ---------------------------------------
say "[2/9] PowerShell 7"
if ! have pwsh; then
    # 用 packages.microsoft.com 的官方 repo
    UB_VER=$(lsb_release -rs)
    wget -q "https://packages.microsoft.com/config/ubuntu/${UB_VER}/packages-microsoft-prod.deb" \
        -O /tmp/packages-microsoft-prod.deb
    dpkg -i /tmp/packages-microsoft-prod.deb
    apt-get update -qq
    apt-get install -y -qq powershell
    rm /tmp/packages-microsoft-prod.deb
fi
pwsh -v | tee -a "$LOG"

say "  -> 裝 VMware.PowerCLI (跑在 $LAB_USER 身分下, 不污染 root)"
sudo -u "$LAB_USER" pwsh -NoProfile -Command '
    if (-not (Get-Module -ListAvailable VMware.PowerCLI)) {
        Install-Module VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber
    }
    if (-not (Get-Module -ListAvailable VMware.Sdk.Vcf.SddcManager -ErrorAction SilentlyContinue)) {
        try { Install-Module VMware.Sdk.Vcf.SddcManager -Scope CurrentUser -Force -AllowClobber } catch { Write-Warning $_ }
    }
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false `
        -DefaultVIServerMode Single -Confirm:$false -Scope AllUsers | Out-Null
    Get-Module -ListAvailable VMware.PowerCLI | Select-Object Name, Version
'

#---------- 3. Python: pyvmomi + requests + 其他 -----------------------------
say "[3/9] Python venv + pyvmomi"
PY_VENV="$LAB_ROOT/.venv"
mkdir -p "$LAB_ROOT"
chown -R "$LAB_USER":"$LAB_USER" "$LAB_ROOT"
sudo -u "$LAB_USER" python3 -m venv "$PY_VENV"
sudo -u "$LAB_USER" "$PY_VENV/bin/pip" install --upgrade pip wheel setuptools >>"$LOG" 2>&1
sudo -u "$LAB_USER" "$PY_VENV/bin/pip" install \
    pyvmomi requests urllib3 PyYAML jinja2 paramiko netaddr \
    "ansible-core>=2.16" >>"$LOG" 2>&1

#---------- 4. Ansible + community.vmware -----------------------------------
say "[4/9] Ansible community.vmware collection"
sudo -u "$LAB_USER" "$PY_VENV/bin/ansible-galaxy" collection install \
    community.vmware community.general ansible.posix \
    --force >>"$LOG" 2>&1 || warn "ansible-galaxy 部分 collection 安裝失敗, 看 log"

#---------- 5. Terraform ----------------------------------------------------
say "[5/9] Terraform (HashiCorp official repo)"
if ! have terraform; then
    install -m 0755 -d /etc/apt/keyrings
    wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
    echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq
    apt-get install -y -qq terraform
fi
terraform -version | head -1 | tee -a "$LOG"

#---------- 6. Docker -------------------------------------------------------
say "[6/9] Docker Engine"
if ! have docker; then
    install -m 0755 -d /etc/apt/keyrings
    wget -qO- https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker "$LAB_USER" || true
fi
systemctl enable --now docker >>"$LOG" 2>&1
docker --version | tee -a "$LOG"

#---------- 7. sops + age (加密 secret) -------------------------------------
say "[7/9] sops + age"
if ! have age; then
    AGE_VER=$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest | jq -r .tag_name)
    wget -qO /tmp/age.tgz "https://github.com/FiloSottile/age/releases/download/${AGE_VER}/age-${AGE_VER}-linux-amd64.tar.gz"
    tar -xzf /tmp/age.tgz -C /tmp
    install -m 0755 /tmp/age/age      /usr/local/bin/age
    install -m 0755 /tmp/age/age-keygen /usr/local/bin/age-keygen
    rm -rf /tmp/age /tmp/age.tgz
fi
if ! have sops; then
    SOPS_VER=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)
    wget -qO /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/${SOPS_VER}/sops-${SOPS_VER}.linux.amd64"
    chmod +x /usr/local/bin/sops
fi
age --version | tee -a "$LOG"
sops --version | tee -a "$LOG"

# 幫 LAB_USER 產 age key (如果還沒)
sudo -u "$LAB_USER" bash -c '
    mkdir -p ~/.config/sops/age
    if [[ ! -f ~/.config/sops/age/keys.txt ]]; then
        age-keygen -o ~/.config/sops/age/keys.txt
        echo "  -> age key 已生成: ~/.config/sops/age/keys.txt"
        echo "     公鑰: $(grep "public key" ~/.config/sops/age/keys.txt | sed "s/# public key: //")"
    fi
'

#---------- 8. GitHub CLI ---------------------------------------------------
say "[8/9] GitHub CLI"
if ! have gh; then
    install -m 0755 -d /etc/apt/keyrings
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq
    apt-get install -y -qq gh
fi
gh --version | head -1 | tee -a "$LOG"

#---------- 9. Lab repo 骨架 ------------------------------------------------
say "[9/9] 建立 $LAB_ROOT 目錄骨架"
sudo -u "$LAB_USER" bash <<EOSU
set -e
cd "$LAB_ROOT"
mkdir -p \
    inventory/secrets \
    layer1-nested \
    layer2-bringup \
    layer3-postbringup \
    layer4-day2 \
    scripts \
    .vscode

# 已經是 git repo 就跳過 init
if [[ ! -d .git ]]; then
    git init -q -b main
    cat > .gitignore <<'EOG'
.venv/
*.log
*.tfstate*
.terraform/
.terraform.lock.hcl
inventory/secrets/*.dec.*
!inventory/secrets/.gitkeep
.DS_Store
EOG
    touch inventory/secrets/.gitkeep
    git add -A
    git -c user.email=lab@local -c user.name=lab commit -q -m "init: scaffold from bootstrap"
fi

# 寫個 .sops.yaml 用 age 公鑰加密 inventory/secrets/*.yaml
AGE_PUB=\$(grep "public key" ~/.config/sops/age/keys.txt | sed 's/# public key: //')
cat > .sops.yaml <<EOSOPS
creation_rules:
  - path_regex: inventory/secrets/.*\\.yaml\$
    age: \$AGE_PUB
EOSOPS

# 寫一個 README 講結構
cat > README.md <<'EOM'
# VCF 9 Lab — Infrastructure as Code

```
.
├── inventory/              # 環境拓樸 (host list, IP, FQDN, VLAN)
│   └── secrets/            # sops+age 加密過的密碼/憑證
├── layer1-nested/          # nested ESXi VM 部署 (William Lam 風格 JSON)
├── layer2-bringup/         # VCF Installer JSON + 推送腳本
├── layer3-postbringup/     # SDDC Manager API: commission/domain/NSX
├── layer4-day2/            # 升級/補丁/擴增, 我們現有 PowerCLI 腳本放這
└── scripts/                # 共用 helper (連線/secret 解密/驗證)
```

## 常用指令

```bash
# 進 venv
source /opt/vcf-lab/.venv/bin/activate

# 解密 secret 然後 source
sops -d inventory/secrets/lab.yaml | yq '...'

# 用 PowerCLI
pwsh -c "Connect-VIServer labvc.lab.com -User administrator@vsphere.local"
```
EOM

EOSU

#---------- 完成 ------------------------------------------------------------
say "完成. 接下來請你以 $LAB_USER 身分:"
say "  1. 重新登入一次 (讓 docker group 生效)"
say "  2. gh auth login         # 登入 GitHub, 之後 push 你的 private repo"
say "  3. cd $LAB_ROOT && git remote add origin git@github.com:<you>/<repo>.git"
say "  4. age 公鑰 (給隊友加 secret 用):"
sudo -u "$LAB_USER" grep "public key" "/home/$LAB_USER/.config/sops/age/keys.txt" 2>/dev/null \
    || sudo -u "$LAB_USER" grep "public key" ~/.config/sops/age/keys.txt 2>/dev/null \
    || true
say "Log 全文: $LOG"
