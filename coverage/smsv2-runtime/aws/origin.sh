#!/usr/bin/env bash
# Controlled origin: every test URI returns 200 and records its fresh case ID.
set -euo pipefail
dnf install -y nginx openssl
install -d -m 0700 /etc/nginx/qualification
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout /etc/nginx/qualification/origin.key \
  -out /etc/nginx/qualification/origin.crt \
  -subj /CN=origin.qualification.test \
  -addext subjectAltName=DNS:origin.qualification.test
chmod 0600 /etc/nginx/qualification/origin.key
cat > /etc/nginx/nginx.conf <<'EOF'
events {}
http {
  log_format qualification escape=json '{"case":"$arg_case","source":"$remote_addr","status":$status,"uri":"$uri"}';
  access_log /var/log/nginx/qualification.jsonl qualification;
  server {
    listen 80 default_server;
    listen 443 ssl default_server;
    ssl_certificate /etc/nginx/qualification/origin.crt;
    ssl_certificate_key /etc/nginx/qualification/origin.key;
    location / {
      default_type application/json;
      return 200 '{"case":"$arg_case","result":"controlled-origin-ok"}\n';
    }
  }
}
EOF
nginx -t
systemctl enable --now nginx
