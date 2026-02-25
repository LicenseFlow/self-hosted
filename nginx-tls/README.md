# Nginx Reverse Proxy + TLS for LicenseFlow Self-Hosted

This guide covers setting up Nginx as a TLS-terminating reverse proxy in front of your LicenseFlow instance.

## Prerequisites

- A running LicenseFlow instance (Docker or bare-metal) on port `3000`
- A domain name with DNS pointed to your server (e.g. `licenses.yourcompany.com`)
- Nginx 1.18+ installed
- Certbot (Let's Encrypt) or your own TLS certificates

---

## 1. Install Nginx & Certbot

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx
```

### RHEL / Rocky / AlmaLinux

```bash
sudo dnf install -y nginx certbot python3-certbot-nginx
sudo systemctl enable --now nginx
```

---

## 2. Obtain a TLS Certificate

```bash
# Stop nginx temporarily for standalone mode (or use --nginx plugin)
sudo certbot certonly --nginx \
  -d licenses.yourcompany.com \
  --agree-tos \
  -m admin@yourcompany.com
```

Certificates will be saved to:
- `/etc/letsencrypt/live/licenses.yourcompany.com/fullchain.pem`
- `/etc/letsencrypt/live/licenses.yourcompany.com/privkey.pem`

### Auto-Renewal

Certbot installs a systemd timer by default. Verify:

```bash
sudo systemctl status certbot.timer
# Or test renewal:
sudo certbot renew --dry-run
```

---

## 3. Nginx Configuration

Create `/etc/nginx/sites-available/licenseflow`:

```nginx
# Redirect HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name licenses.yourcompany.com;
    return 301 https://$host$request_uri;
}

# HTTPS reverse proxy
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name licenses.yourcompany.com;

    # ── TLS Certificates ──────────────────────────────────────
    ssl_certificate     /etc/letsencrypt/live/licenses.yourcompany.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/licenses.yourcompany.com/privkey.pem;

    # ── TLS Hardening ─────────────────────────────────────────
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;

    # ── Security Headers ──────────────────────────────────────
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # ── Rate Limiting ─────────────────────────────────────────
    # Define in http block: limit_req_zone $binary_remote_addr zone=api:10m rate=100r/s;
    # Define in http block: limit_req_zone $binary_remote_addr zone=auth:10m rate=10r/s;

    location /api/auth/ {
        limit_req zone=auth burst=20 nodelay;
        proxy_pass http://127.0.0.1:3000;
        include /etc/nginx/proxy_params;
    }

    location /api/ {
        limit_req zone=api burst=50 nodelay;
        proxy_pass http://127.0.0.1:3000;
        include /etc/nginx/proxy_params;
    }

    # ── Main App ──────────────────────────────────────────────
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts for long-running requests
        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }

    # ── Static Assets Caching ─────────────────────────────────
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # ── Health Check ──────────────────────────────────────────
    location /health {
        proxy_pass http://127.0.0.1:3000;
        access_log off;
    }
}
```

### Enable the site

```bash
sudo ln -s /etc/nginx/sites-available/licenseflow /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### Add rate-limit zones to `/etc/nginx/nginx.conf`

Inside the `http {}` block:

```nginx
http {
    # ... existing config ...

    limit_req_zone $binary_remote_addr zone=api:10m rate=100r/s;
    limit_req_zone $binary_remote_addr zone=auth:10m rate=10r/s;
}
```

---

## 4. Docker Compose Integration

If using Docker Compose, expose LicenseFlow only on localhost:

```yaml
services:
  licenseflow:
    # ...
    ports:
      - "127.0.0.1:3000:3000"   # Only accessible via Nginx
```

---

## 5. Verify

```bash
# Test TLS grade
curl -I https://licenses.yourcompany.com

# Check certificate
echo | openssl s_client -connect licenses.yourcompany.com:443 -servername licenses.yourcompany.com 2>/dev/null | openssl x509 -noout -dates

# Test with SSL Labs (web)
# https://www.ssllabs.com/ssltest/analyze.html?d=licenses.yourcompany.com
```

---

## 6. Troubleshooting

| Issue | Solution |
|-------|----------|
| `502 Bad Gateway` | LicenseFlow not running on port 3000 — check `docker-compose ps` |
| Certificate errors | Re-run `certbot` or check file paths in nginx config |
| Mixed content warnings | Ensure `APP_URL` env var uses `https://` |
| WebSocket failures | Verify `Upgrade` / `Connection` headers are set |

---

## 7. Using Your Own Certificates (Non-Let's Encrypt)

Replace the `ssl_certificate` lines with your cert paths:

```nginx
ssl_certificate     /etc/ssl/certs/yourcompany.crt;
ssl_certificate_key /etc/ssl/private/yourcompany.key;
ssl_trusted_certificate /etc/ssl/certs/ca-chain.crt;  # For OCSP stapling
```

---

## Related

- [Self-Hosted README](../README.md)
- [Kubernetes Ingress TLS](../kubernetes/helm/templates/ingress.yaml)
- [Docker Compose Setup](../docker/)
