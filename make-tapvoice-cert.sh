#!/bin/bash
# make-tapvoice-cert.sh: 创建 tapvoice 专用自签名代码签名证书（一次性运行）
# 之后重编译只需 build-tapvoice.sh 重签，辅助功能权限不会丢
set -e
CERT="TapVoice Dev"
TMP=$(mktemp -d)
cd "$TMP"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=$CERT/O=TapVoice/" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null
# 导入登录钥匙串并允许 codesign 使用
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -passout pass:tapvoice 2>/dev/null
security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P tapvoice -T /usr/bin/codesign -T /usr/bin/security
# 标记为始终信任（代码签名用途）
security add-trusted-cert -r trustAsRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
rm -rf "$TMP"
security find-certificate -c "$CERT" ~/Library/Keychains/login.keychain-db >/dev/null && echo "cert ready: $CERT"
