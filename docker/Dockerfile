# LicenseFlow Self-Hosted Edition
# Multi-stage build for optimized production image

# Stage 1: Build the frontend
FROM node:20-alpine AS frontend-builder

WORKDIR /app

# Copy package files
COPY package*.json ./
COPY bun.lockb ./

# Install dependencies
RUN npm ci --legacy-peer-deps

# Copy source code
COPY . .

# Build the frontend
RUN npm run build

# Stage 2: Build Edge Functions runtime
FROM denoland/deno:2.1.0 AS functions-builder

WORKDIR /app

# Copy edge functions
COPY supabase/functions ./functions

# Cache dependencies
RUN deno cache functions/*/index.ts || true

# Stage 3: Production image with Nginx + Deno
FROM nginx:alpine AS production

# Install Deno runtime
RUN apk add --no-cache curl unzip \
    && curl -fsSL https://deno.land/x/install/install.sh | sh \
    && mv /root/.deno/bin/deno /usr/local/bin/deno \
    && rm -rf /root/.deno

# Install supervisor for process management
RUN apk add --no-cache supervisor postgresql-client

# Copy built frontend
COPY --from=frontend-builder /app/dist /usr/share/nginx/html

# Copy edge functions
COPY --from=functions-builder /app/functions /app/functions

# Copy nginx configuration
COPY self-hosted/docker/nginx.conf /etc/nginx/nginx.conf

# Copy supervisor configuration
COPY self-hosted/docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy entrypoint script
COPY self-hosted/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Environment variables
ENV SUPABASE_URL=""
ENV SUPABASE_ANON_KEY=""
ENV SUPABASE_SERVICE_ROLE_KEY=""
ENV DATABASE_URL=""
ENV JWT_SECRET=""
ENV STRIPE_SECRET_KEY=""
ENV SMTP_HOST=""
ENV SMTP_PORT="587"
ENV SMTP_USER=""
ENV SMTP_PASS=""
ENV APP_URL="http://localhost:3000"

# Expose ports
EXPOSE 80 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
