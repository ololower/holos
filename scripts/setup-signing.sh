#!/bin/bash
# Створює в login-keychain постійний self-signed сертифікат «Holos Local Signing».
# З ним macOS упізнає Holos за сертифікатом, а не за хешем коду, тож дозволи
# (мікрофон, універсальний доступ) не злітають після кожного перезбирання.
# Видалити: Keychain Access → login → «Holos Local Signing» → Delete.
set -euo pipefail

NAME="Holos Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Сертифікат «${NAME}» уже є"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# Системний LibreSSL: його PKCS#12 без проблем імпортує security
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout pass:holos

# -T: codesign може користуватися ключем без запиту пароля
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P holos -T /usr/bin/codesign >/dev/null
echo "Сертифікат «${NAME}» створено"
