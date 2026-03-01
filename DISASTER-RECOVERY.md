# LicenseFlow Self-Hosted: Disaster Recovery, High Availability & Multi-Region Guide

This guide covers disaster recovery (DR), load balancing, failover, and multi-regional deployment strategies for LicenseFlow Self-Hosted Edition.

---

## Table of Contents

1. [Disaster Recovery](#disaster-recovery)
2. [Load Balancing](#load-balancing)
3. [Failover](#failover)
4. [Multi-Regional Access](#multi-regional-access)

---

## Disaster Recovery

### Recovery Objectives

| Metric | Target | Description |
|--------|--------|-------------|
| **RPO** (Recovery Point Objective) | < 1 hour | Maximum acceptable data loss |
| **RTO** (Recovery Time Objective) | < 4 hours | Maximum acceptable downtime |

### Automated Backups

#### PostgreSQL WAL Archiving

Enable Write-Ahead Log (WAL) archiving for continuous point-in-time recovery:

```bash
# postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'aws s3 cp %p s3://licenseflow-wal-archive/%f --region eu-west-1'
archive_timeout = 300  # Force archive every 5 minutes
```

#### Daily Base Backups (Docker)

```bash
#!/bin/bash
# backup.sh - Run via cron: 0 2 * * * /opt/licenseflow/backup.sh

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups"
S3_BUCKET="s3://licenseflow-backups"

# Create base backup
docker-compose exec -T postgres pg_basebackup \
  -U licenseflow \
  -D "${BACKUP_DIR}/${TIMESTAMP}" \
  -Ft -z -P

# Upload to S3
aws s3 cp "${BACKUP_DIR}/${TIMESTAMP}" \
  "${S3_BUCKET}/${TIMESTAMP}/" \
  --recursive

# Cleanup local backups older than 7 days
find ${BACKUP_DIR} -type d -mtime +7 -exec rm -rf {} +

# Cleanup S3 backups older than 30 days (via lifecycle policy)
echo "Backup ${TIMESTAMP} completed successfully"
```

#### Daily Base Backups (Kubernetes)

```yaml
# backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: licenseflow-db-backup
  namespace: licenseflow
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:16
            command:
            - /bin/bash
            - -c
            - |
              pg_dump -h $PGHOST -U $PGUSER $PGDATABASE | \
              gzip | \
              aws s3 cp - s3://$S3_BUCKET/$(date +%Y%m%d_%H%M%S).sql.gz
            envFrom:
            - secretRef:
                name: licenseflow-db-credentials
            - secretRef:
                name: licenseflow-s3-credentials
          restartPolicy: OnFailure
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
```

### Restore Procedures

#### Docker Restore

```bash
# 1. Stop the application
docker-compose stop licenseflow

# 2. Restore from SQL dump
cat backup.sql | docker-compose exec -T postgres psql -U licenseflow licenseflow

# -- OR restore from base backup --
# 2a. Stop PostgreSQL
docker-compose stop postgres

# 2b. Replace data directory
docker-compose run --rm -v /backups/20260301_020000:/backup postgres \
  bash -c "rm -rf /var/lib/postgresql/data/* && \
           tar xzf /backup/base.tar.gz -C /var/lib/postgresql/data/"

# 3. Start services
docker-compose up -d

# 4. Verify
docker-compose exec postgres pg_isready -U licenseflow
curl -f http://localhost:3000/health/ready
```

#### Kubernetes Restore

```bash
# 1. Scale down application
kubectl scale deployment licenseflow --replicas=0 -n licenseflow

# 2. Download backup from S3
aws s3 cp s3://licenseflow-backups/20260301_020000.sql.gz ./backup.sql.gz
gunzip backup.sql.gz

# 3. Restore
cat backup.sql | kubectl exec -i -n licenseflow postgres-0 -- \
  psql -U licenseflow licenseflow

# 4. Scale up application
kubectl scale deployment licenseflow --replicas=3 -n licenseflow

# 5. Verify
kubectl exec -n licenseflow postgres-0 -- pg_isready -U licenseflow
kubectl run --rm -it --restart=Never healthcheck --image=curlimages/curl -- \
  curl -f http://licenseflow.licenseflow.svc:3000/health/ready
```

### Incident Response Runbook

```
┌──────────────────────────────────────────────────────────────┐
│                    INCIDENT RESPONSE                         │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1. DETECT                                                   │
│     • Monitoring alert fires (Prometheus / uptime check)     │
│     • Check status page: GET /health/ready                   │
│                                                              │
│  2. ASSESS                                                   │
│     • Identify scope: full outage vs partial degradation     │
│     • Check logs: docker-compose logs / kubectl logs          │
│     • Check database: pg_isready                             │
│     • Check Redis: redis-cli ping                            │
│                                                              │
│  3. COMMUNICATE                                              │
│     • Update status page                                     │
│     • Notify stakeholders via #incidents channel             │
│                                                              │
│  4. MITIGATE                                                 │
│     • If DB failure → trigger failover (see Failover section)│
│     • If app failure → restart / rollback deployment         │
│     • If data loss → restore from backup (see above)         │
│                                                              │
│  5. RECOVER                                                  │
│     • Verify all health endpoints return 200                 │
│     • Run smoke tests against critical API paths             │
│     • Confirm license validation is functional               │
│                                                              │
│  6. POST-MORTEM                                              │
│     • Document timeline, root cause, and remediation         │
│     • Update runbook with lessons learned                    │
│     • Schedule follow-up actions                             │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Load Balancing

### Docker: Nginx Reverse Proxy

```nginx
# nginx/licenseflow-lb.conf

upstream licenseflow_app {
    least_conn;

    server app1:3000 max_fails=3 fail_timeout=30s;
    server app2:3000 max_fails=3 fail_timeout=30s;
    server app3:3000 max_fails=3 fail_timeout=30s;

    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name licenses.yourdomain.com;

    ssl_certificate     /etc/ssl/certs/licenseflow.crt;
    ssl_certificate_key /etc/ssl/private/licenseflow.key;

    # Health check endpoint (not proxied to upstream)
    location /nginx-health {
        access_log off;
        return 200 "OK";
    }

    # API rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=100r/s;
    limit_req_zone $binary_remote_addr zone=auth:10m rate=10r/s;

    location /api/v1/auth/ {
        limit_req zone=auth burst=20 nodelay;
        proxy_pass http://licenseflow_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/ {
        limit_req zone=api burst=50 nodelay;
        proxy_pass http://licenseflow_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    location / {
        proxy_pass http://licenseflow_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Docker Compose (Multi-Instance)

```yaml
# docker-compose.ha.yaml
version: '3.8'

services:
  app1:
    image: licenseflow/licenseflow:latest
    env_file: .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health/ready"]
      interval: 15s
      timeout: 5s
      retries: 3

  app2:
    image: licenseflow/licenseflow:latest
    env_file: .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health/ready"]
      interval: 15s
      timeout: 5s
      retries: 3

  app3:
    image: licenseflow/licenseflow:latest
    env_file: .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health/ready"]
      interval: 15s
      timeout: 5s
      retries: 3

  nginx:
    image: nginx:alpine
    ports:
      - "443:443"
    volumes:
      - ./nginx/licenseflow-lb.conf:/etc/nginx/conf.d/default.conf
      - ./certs:/etc/ssl
    depends_on:
      - app1
      - app2
      - app3
    restart: unless-stopped
```

### Kubernetes: Ingress & HPA

```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: licenseflow
  namespace: licenseflow
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/rate-limit: "100"
    nginx.ingress.kubernetes.io/rate-limit-window: "1s"
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/session-cookie-name: "lf-sticky"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "3600"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - licenses.yourdomain.com
    secretName: licenseflow-tls
  rules:
  - host: licenses.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: licenseflow
            port:
              number: 3000
---
# hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: licenseflow
  namespace: licenseflow
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: licenseflow
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

---

## Failover

### Database Failover

#### Docker: pg_auto_failover

```yaml
# docker-compose.db-ha.yaml
version: '3.8'

services:
  pg-monitor:
    image: citusdata/pg_auto_failover:latest
    environment:
      PGDATA: /var/lib/postgresql/monitor
    command: pg_autoctl create monitor --pgdata /var/lib/postgresql/monitor --pgport 5000
    volumes:
      - pg_monitor_data:/var/lib/postgresql/monitor

  pg-primary:
    image: citusdata/pg_auto_failover:latest
    environment:
      PGDATA: /var/lib/postgresql/data
    command: >
      pg_autoctl create postgres
        --pgdata /var/lib/postgresql/data
        --pgport 5432
        --monitor postgresql://autoctl_node@pg-monitor:5000/pg_auto_failover
        --name primary
    volumes:
      - pg_primary_data:/var/lib/postgresql/data
    depends_on:
      - pg-monitor

  pg-secondary:
    image: citusdata/pg_auto_failover:latest
    environment:
      PGDATA: /var/lib/postgresql/data
    command: >
      pg_autoctl create postgres
        --pgdata /var/lib/postgresql/data
        --pgport 5432
        --monitor postgresql://autoctl_node@pg-monitor:5000/pg_auto_failover
        --name secondary
    volumes:
      - pg_secondary_data:/var/lib/postgresql/data
    depends_on:
      - pg-monitor
      - pg-primary

volumes:
  pg_monitor_data:
  pg_primary_data:
  pg_secondary_data:
```

#### Kubernetes: Patroni

```yaml
# Helm values for Patroni-based PostgreSQL HA
postgresql:
  replication:
    enabled: true
    readReplicas: 2
    synchronousCommit: "on"
  
  patroni:
    enabled: true
    ttl: 30
    loopWait: 10
    retryTimeout: 10
    maximumLagOnFailover: 33554432  # 32MB

  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
```

### Application Failover

```yaml
# deployment.yaml (Kubernetes)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: licenseflow
  namespace: licenseflow
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  template:
    spec:
      containers:
      - name: licenseflow
        image: licenseflow/licenseflow:latest
        ports:
        - containerPort: 3000
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /health/live
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 5
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: "1"
            memory: 1Gi
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: licenseflow
```

### Redis Sentinel (Cache Failover)

```yaml
# docker-compose.redis-ha.yaml
version: '3.8'

services:
  redis-master:
    image: redis:7-alpine
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_master_data:/data

  redis-replica:
    image: redis:7-alpine
    command: redis-server --appendonly yes --replicaof redis-master 6379 --masterauth ${REDIS_PASSWORD} --requirepass ${REDIS_PASSWORD}
    depends_on:
      - redis-master

  redis-sentinel-1:
    image: redis:7-alpine
    command: >
      sh -c 'cat > /tmp/sentinel.conf << EOF
      sentinel monitor licenseflow redis-master 6379 2
      sentinel auth-pass licenseflow ${REDIS_PASSWORD}
      sentinel down-after-milliseconds licenseflow 5000
      sentinel failover-timeout licenseflow 10000
      sentinel parallel-syncs licenseflow 1
      EOF
      redis-sentinel /tmp/sentinel.conf'
    depends_on:
      - redis-master
      - redis-replica

  redis-sentinel-2:
    image: redis:7-alpine
    command: >
      sh -c 'cat > /tmp/sentinel.conf << EOF
      sentinel monitor licenseflow redis-master 6379 2
      sentinel auth-pass licenseflow ${REDIS_PASSWORD}
      sentinel down-after-milliseconds licenseflow 5000
      sentinel failover-timeout licenseflow 10000
      sentinel parallel-syncs licenseflow 1
      EOF
      redis-sentinel /tmp/sentinel.conf'
    depends_on:
      - redis-master
      - redis-replica

  redis-sentinel-3:
    image: redis:7-alpine
    command: >
      sh -c 'cat > /tmp/sentinel.conf << EOF
      sentinel monitor licenseflow redis-master 6379 2
      sentinel auth-pass licenseflow ${REDIS_PASSWORD}
      sentinel down-after-milliseconds licenseflow 5000
      sentinel failover-timeout licenseflow 10000
      sentinel parallel-syncs licenseflow 1
      EOF
      redis-sentinel /tmp/sentinel.conf'
    depends_on:
      - redis-master
      - redis-replica

volumes:
  redis_master_data:
```

---

## Multi-Regional Access

### Architecture Overview

```
                          ┌──────────────────────┐
                          │   DNS / GeoDNS       │
                          │  (Cloudflare / R53)   │
                          └──────────┬───────────┘
                                     │
               ┌─────────────────────┼─────────────────────┐
               │                     │                     │
     ┌─────────▼──────────┐ ┌───────▼────────┐ ┌─────────▼──────────┐
     │   EU-WEST (London)  │ │  US-EAST (VA)  │ │  APAC (Singapore)  │
     │                     │ │                │ │                     │
     │  ┌───────────────┐  │ │ ┌────────────┐ │ │  ┌───────────────┐  │
     │  │  LB / Ingress │  │ │ │ LB/Ingress │ │ │  │  LB / Ingress │  │
     │  └───────┬───────┘  │ │ └─────┬──────┘ │ │  └───────┬───────┘  │
     │          │          │ │       │        │ │          │          │
     │  ┌───────▼───────┐  │ │ ┌─────▼──────┐ │ │  ┌───────▼───────┐  │
     │  │  App Replicas │  │ │ │ App Replicas│ │ │  │  App Replicas │  │
     │  │  (3x pods)    │  │ │ │ (3x pods)  │ │ │  │  (3x pods)    │  │
     │  └───────┬───────┘  │ │ └─────┬──────┘ │ │  └───────┬───────┘  │
     │          │          │ │       │        │ │          │          │
     │  ┌───────▼───────┐  │ │ ┌─────▼──────┐ │ │  ┌───────▼───────┐  │
     │  │  PG Primary   │  │ │ │ PG Replica  │ │ │  │  PG Replica   │  │
     │  │  (Read/Write) │◄─┼─┼─┤ (Read Only)│ │ │  │  (Read Only)  │  │
     │  └───────────────┘  │ │ └────────────┘ │ │  └───────────────┘  │
     │                     │ │                │ │                     │
     │  ┌───────────────┐  │ │ ┌────────────┐ │ │  ┌───────────────┐  │
     │  │  Redis Primary│  │ │ │Redis Replica│ │ │  │ Redis Replica │  │
     │  └───────────────┘  │ │ └────────────┘ │ │  └───────────────┘  │
     │                     │ │                │ │                     │
     └─────────────────────┘ └────────────────┘ └─────────────────────┘
                                     │
                          ┌──────────▼───────────┐
                          │   CDN (CloudFront /   │
                          │   Cloudflare)         │
                          │   Static Assets       │
                          └──────────────────────┘
```

### DNS-Based Routing

#### Cloudflare Load Balancing

```json
{
  "description": "LicenseFlow multi-region pool",
  "pools": [
    {
      "name": "eu-west",
      "origins": [{ "address": "eu.licenses.yourdomain.com" }],
      "check_regions": ["WEU"]
    },
    {
      "name": "us-east",
      "origins": [{ "address": "us.licenses.yourdomain.com" }],
      "check_regions": ["ENA"]
    },
    {
      "name": "apac",
      "origins": [{ "address": "apac.licenses.yourdomain.com" }],
      "check_regions": ["SEA"]
    }
  ],
  "steering_policy": "geo",
  "fallback_pool": "eu-west"
}
```

#### AWS Route 53 Geolocation

```bash
# EU traffic → eu-west
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch '{
  "Changes": [{
    "Action": "CREATE",
    "ResourceRecordSet": {
      "Name": "licenses.yourdomain.com",
      "Type": "A",
      "SetIdentifier": "eu-west",
      "GeoLocation": { "ContinentCode": "EU" },
      "AliasTarget": {
        "HostedZoneId": "Z1234",
        "DNSName": "eu-alb.yourdomain.com",
        "EvaluateTargetHealth": true
      }
    }
  }]
}'
```

### PostgreSQL Read Replicas

```yaml
# Helm values for cross-region read replicas
postgresql:
  primary:
    region: eu-west-1
    persistence:
      size: 100Gi

  readReplicas:
    - name: us-east-replica
      region: us-east-1
      persistence:
        size: 100Gi
    - name: apac-replica
      region: ap-southeast-1
      persistence:
        size: 100Gi

  # Application connection string routing
  connectionPooler:
    enabled: true
    mode: transaction
    maxConnections: 200
```

Configure your application to route read queries to the nearest replica:

```bash
# Environment variables per region
# EU (primary - read/write)
DATABASE_URL=postgresql://user:pass@pg-primary.eu-west-1:5432/licenseflow
DATABASE_READ_URL=postgresql://user:pass@pg-primary.eu-west-1:5432/licenseflow

# US (replica - reads only, writes to primary)
DATABASE_URL=postgresql://user:pass@pg-primary.eu-west-1:5432/licenseflow
DATABASE_READ_URL=postgresql://user:pass@pg-replica.us-east-1:5432/licenseflow

# APAC (replica - reads only, writes to primary)
DATABASE_URL=postgresql://user:pass@pg-primary.eu-west-1:5432/licenseflow
DATABASE_READ_URL=postgresql://user:pass@pg-replica.ap-southeast-1:5432/licenseflow
```

### CDN Configuration

```yaml
# Cloudflare Pages / CloudFront for static assets
cdn:
  enabled: true
  provider: cloudfront  # or cloudflare

  cloudfront:
    distribution:
      origins:
        - domainName: licenses.yourdomain.com
          originPath: ""
          s3OriginConfig:
            originAccessIdentity: ""
      defaultCacheBehavior:
        viewerProtocolPolicy: redirect-to-https
        compress: true
        ttl:
          default: 86400
          max: 31536000
        allowedMethods: ["GET", "HEAD", "OPTIONS"]
      cacheBehaviors:
        - pathPattern: "/api/*"
          ttl: { default: 0 }
          allowedMethods: ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
        - pathPattern: "/assets/*"
          ttl: { default: 31536000 }
          compress: true
```

---

## Checklist

Use this checklist when setting up your HA / DR environment:

- [ ] WAL archiving configured and verified
- [ ] Daily backups running and uploaded to off-site storage
- [ ] Backup restore tested (at least quarterly)
- [ ] Database replication lag monitored (< 100ms target)
- [ ] Load balancer health checks passing
- [ ] Application runs minimum 3 replicas
- [ ] Redis Sentinel quorum configured (3 sentinels)
- [ ] DNS failover / GeoDNS routing tested
- [ ] CDN serving static assets with proper cache headers
- [ ] Monitoring & alerting configured (Prometheus + Alertmanager)
- [ ] Incident response runbook reviewed by team
- [ ] DR drill completed (at least bi-annually)

---

## Getting Help

- 📚 [Main Documentation](https://docs.licenseflow.dev/self-hosted)
- 📖 [Self-Hosted README](./README.md)
- 💬 [Community Discord](https://discord.gg/licenseflow)
- 📧 [Enterprise Support](mailto:enterprise@licenseflow.dev)
