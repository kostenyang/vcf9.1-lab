#!/usr/bin/env bash
# Source 這支會把 inventory/secrets/lab.yaml (sops 加密) 解開, 把欄位 export 成 env var.
#
#   source scripts/load-secrets.sh
#   echo "$ESXI_ROOT_PW"
#
# 需要: sops, yq, age 私鑰 (~/.config/sops/age/keys.txt)

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$REPO_ROOT/inventory/secrets/lab.yaml"

if [[ ! -f "$SECRETS" ]]; then
    echo "[load-secrets] $SECRETS 不存在, 先 cp inventory/secrets/lab.example.yaml ... 再 sops -e -i" >&2
    return 1 2>/dev/null || exit 1
fi
if ! command -v sops >/dev/null; then echo "需要 sops"; return 1 2>/dev/null || exit 1; fi
if ! command -v yq   >/dev/null; then echo "需要 yq";   return 1 2>/dev/null || exit 1; fi

DEC="$(sops -d "$SECRETS")"

export ESXI_ROOT_PW="$(echo "$DEC"        | yq -r '.esxi.root_pw')"
export OUTER_VC_SSO_PW="$(echo "$DEC"     | yq -r '.outer_vcenter.sso_admin_pw')"
export INNER_VC_SSO_PW="$(echo "$DEC"     | yq -r '.inner_vcenter.sso_admin_pw')"
export SDDC_ADMIN_PW="$(echo "$DEC"       | yq -r '.sddc_manager.admin_pw')"
export SDDC_ROOT_PW="$(echo "$DEC"        | yq -r '.sddc_manager.root_pw')"
export NSX_ADMIN_PW="$(echo "$DEC"        | yq -r '.nsx.admin_pw')"
export AD_ADMIN_USER="$(echo "$DEC"       | yq -r '.ad.domain_admin_user')"
export AD_ADMIN_PW="$(echo "$DEC"         | yq -r '.ad.domain_admin_pw')"
export VM_ROOT_PW="$(echo "$DEC"          | yq -r '.deploy_defaults.vm_root_pw')"

unset DEC
echo "[load-secrets] OK — secrets 已 export 到當前 shell."
