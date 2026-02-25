# LicenseFlow Self-Hosted Edition

Deploy LicenseFlow on your own infrastructure with complete control over your data and configuration.

## 🚀 Quick Start

### Prerequisites

- Docker 20.10+ and Docker Compose 2.0+
- OR Kubernetes 1.24+ with Helm 3.0+
- 2GB RAM minimum (4GB recommended)
- 10GB disk space

### Docker Deployment (Recommended for Small Teams)

```bash
# Clone the repository
git clone https://github.com/licenseflow/self-hosted.git
cd self-hosted/docker

# Configure environment
cp .env.example .env
nano .env  # Edit with your settings

# Start the stack
docker-compose up -d

# Check status
docker-compose ps
docker-compose logs -f licenseflow
```

Access the application at `http://localhost:3000`

### Kubernetes Deployment (Recommended for Production)

```bash
# Add the Helm repository
helm repo add licenseflow https://charts.licenseflow.io
helm repo update

# Create namespace
kubectl create namespace licenseflow

# Install with custom values
helm install licenseflow licenseflow/licenseflow \
  --namespace licenseflow \
  --values my-values.yaml

# Or use the bundled manifests
kubectl apply -f kubernetes/deployment.yaml
```

## 📋 Configuration

### Required Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | `postgresql://user:pass@host:5432/db` |
| `JWT_SECRET` | Secret for JWT signing (min 32 chars) | `openssl rand -base64 32` |

### Optional Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `APP_URL` | Public URL of your instance | `http://localhost:3000` |
| `STRIPE_SECRET_KEY` | Stripe API key for billing | - |
| `SMTP_HOST` | Email server hostname | - |
| `SMTP_PORT` | Email server port | `587` |
| `SMTP_USER` | Email username | - |
| `SMTP_PASS` | Email password | - |
| `REDIS_URL` | Redis connection for caching | - |

### Generating Secrets

```bash
# Generate JWT secret
openssl rand -base64 32

# Generate PostgreSQL password
openssl rand -base64 24 | tr -d '/+='
```

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Load Balancer                            │
│                    (Nginx / Cloud LB / Ingress)                 │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│                    LicenseFlow App                              │
│  ┌─────────────────┐    ┌─────────────────┐                     │
│  │   Frontend      │    │  Edge Functions │                     │
│  │   (React/Vite)  │    │  (Deno Runtime) │                     │
│  └─────────────────┘    └─────────────────┘                     │
└─────────────┬───────────────────┬───────────────────────────────┘
              │                   │
┌─────────────▼─────────┐ ┌───────▼─────────┐
│     PostgreSQL        │ │      Redis      │
│   (Primary Data)      │ │   (Cache/Rate)  │
└───────────────────────┘ └─────────────────┘
```

## 🔒 Security Hardening

### Network Security

```yaml
# Restrict database access
postgresql:
  primary:
    networkPolicy:
      enabled: true
      allowExternal: false
```

### TLS / SSL

**Nginx (recommended for Docker):** See the full [Nginx TLS guide](nginx-tls/README.md) with a production-ready config, Let's Encrypt auto-renewal, HSTS, OCSP stapling, and rate-limiting. A drop-in config file is at [`nginx-tls/licenseflow.conf`](nginx-tls/licenseflow.conf).

**Kubernetes Ingress + cert-manager:**

```yaml
# Helm values for TLS
ingress:
  enabled: true
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - secretName: licenseflow-tls
      hosts:
        - licenses.yourdomain.com
```

### Rate Limiting

The built-in Nginx configuration includes rate limiting:
- API endpoints: 100 requests/second
- Auth endpoints: 10 requests/second

## 📊 Monitoring

### Health Endpoints

- `GET /health` - Basic health check
- `GET /health/ready` - Readiness probe (includes DB check)
- `GET /health/live` - Liveness probe

### Prometheus Metrics (Optional)

```yaml
# Enable in Helm values
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

### Log Aggregation

```bash
# Docker logs
docker-compose logs -f licenseflow

# Kubernetes logs
kubectl logs -f deployment/licenseflow -n licenseflow
```

## 🔄 Backup & Recovery

### Database Backup

```bash
# Manual backup
docker-compose exec postgres pg_dump -U licenseflow licenseflow > backup.sql

# Kubernetes backup
kubectl exec -n licenseflow postgres-0 -- pg_dump -U licenseflow licenseflow > backup.sql
```

### Automated Backups (Helm)

```yaml
backup:
  enabled: true
  schedule: "0 2 * * *"  # Daily at 2 AM
  retention: 7
  s3:
    bucket: "licenseflow-backups"
    region: "us-east-1"
```

### Recovery

```bash
# Restore from backup
cat backup.sql | docker-compose exec -T postgres psql -U licenseflow licenseflow

# Kubernetes restore
cat backup.sql | kubectl exec -i -n licenseflow postgres-0 -- psql -U licenseflow licenseflow
```

## ⬆️ Upgrades

### Docker Upgrade

```bash
# Pull latest images
docker-compose pull

# Restart with new version
docker-compose up -d

# Run migrations (if any)
docker-compose exec licenseflow /app/migrate.sh
```

### Kubernetes Upgrade

```bash
# Update Helm chart
helm repo update
helm upgrade licenseflow licenseflow/licenseflow \
  --namespace licenseflow \
  --values my-values.yaml
```

## 🛠️ Troubleshooting

### Common Issues

**Database Connection Failed**
```bash
# Check PostgreSQL status
docker-compose exec postgres pg_isready -U licenseflow

# Check connectivity
docker-compose exec licenseflow nc -zv postgres 5432
```

**Application Won't Start**
```bash
# Check logs
docker-compose logs licenseflow

# Verify environment
docker-compose exec licenseflow env | grep -E "(DATABASE|JWT)"
```

**High Memory Usage**
```yaml
# Adjust resource limits
resources:
  limits:
    memory: "1Gi"
```

### Getting Help

- 📚 [Documentation](https://docs.licenseflow.dev/self-hosted)
- 💬 [Community Discord](https://discord.gg/licenseflow)
- 📧 [Enterprise Support](mailto:enterprise@licenseflow.dev)

## 📄 License

LicenseFlow Self-Hosted Edition requires an Enterprise license for production use.
Contact sales@licenseflow.dev for licensing options.
