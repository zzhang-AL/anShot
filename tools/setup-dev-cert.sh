#!/usr/bin/env bash
#
# setup-dev-cert.sh —— 检查或创建本地代码签名自签名证书 "anShot Dev"
#
# ── 为什么需要固定自签名证书 ────────────────────────────────────
#
# macOS TCC（屏幕录制 / 辅助功能）把权限锚定在应用的 Designated Requirement
# （Bundle ID + 代码签名证书哈希）上。若使用 Ad-hoc 签名（`-`），每次重编译都会
# 生成新的 CDHash，导致开发阶段频繁失效、需要反复去系统设置重新勾选权限。
# 创建并信任名为 "anShot Dev" 的本地代码签名证书后，重编译不会破坏 TCC 授权。
#
set -euo pipefail

CERT_NAME="${1:-anShot Dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

# 若登录钥匙串已存在有效的代码签名身份，则直接返回。
if security find-identity -v -p codesigning "${KEYCHAIN}" 2>/dev/null | grep -Fq "\"${CERT_NAME}\""; then
    echo "✅ 登录钥匙串已存在代码签名证书：${CERT_NAME}"
    security find-identity -v -p codesigning "${KEYCHAIN}" | grep -F "\"${CERT_NAME}\"" || true
    exit 0
fi

echo "正在生成本地自签名代码签名证书：${CERT_NAME}..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CONF="${TMP_DIR}/cert.cfg"
KEY="${TMP_DIR}/dev.key"
CRT="${TMP_DIR}/dev.crt"
P12="${TMP_DIR}/dev.p12"
P12_PASS="anshot-dev-local"

cat > "${CONF}" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = codesign_ext
prompt = no

[req_distinguished_name]
CN = ${CERT_NAME}

[codesign_ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${KEY}" \
    -out "${CRT}" \
    -days 3650 \
    -config "${CONF}" >/dev/null 2>&1

openssl pkcs12 -export \
    -out "${P12}" \
    -inkey "${KEY}" \
    -in "${CRT}" \
    -passout "pass:${P12_PASS}" \
    -legacy >/dev/null 2>&1 || \
openssl pkcs12 -export \
    -out "${P12}" \
    -inkey "${KEY}" \
    -in "${CRT}" \
    -passout "pass:${P12_PASS}" >/dev/null 2>&1

security import "${P12}" -k "${KEYCHAIN}" -P "${P12_PASS}" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security add-trusted-cert -d -r trustRoot -p codeSign -k "${KEYCHAIN}" "${CRT}" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning "${KEYCHAIN}" 2>/dev/null | grep -Fq "\"${CERT_NAME}\""; then
    echo "✅ 已成功导入代码签名证书：${CERT_NAME}"
    echo "   如需使 codesign 访问钥匙串免弹窗，可在「钥匙串访问」中将私钥访问控制设为允许 codesign。"
else
    echo "⚠ 证书已生成但尚未标记为可信代码签名身份，请在「钥匙串访问」中手动信任「${CERT_NAME}」用于代码签名。" >&2
    exit 1
fi
