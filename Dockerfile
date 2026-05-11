# ---- builder/scanner stage ----
FROM python:3.12-slim AS base

WORKDIR /app

# Install trivy and helm via apt/official repos
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    wget \
    apt-transport-https \
    gnupg \
    && wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
       > /etc/apt/sources.list.d/trivy.list \
    && curl https://baltocdn.com/helm/signing.asc | gpg --dearmor -o /usr/share/keyrings/helm.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
       > /etc/apt/sources.list.d/helm-stable-debian.list \
    && apt-get update && apt-get install -y --no-install-recommends trivy helm \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy source and helm chart for scanning
COPY src/ ./src/
COPY helm/ ./helm/

# Scan Python source (filesystem scan)
RUN trivy fs --exit-code 1 --severity HIGH,CRITICAL --no-progress ./src || true

# Lint helm chart
RUN helm lint ./helm

# Scan helm chart (config/misconfig scan)
RUN trivy config --exit-code 1 --severity HIGH,CRITICAL --no-progress ./helm || true

# ---- runtime stage ----
FROM python:3.12-slim

WORKDIR /app

# Non-root user
RUN useradd -r -u 1000 -g root appuser

COPY --from=base /app/src ./src

USER 1000

ARG BUILD_VERSION=dev
ENV BUILD_VERSION=${BUILD_VERSION}
ENV APP_COLOR=blue
ENV PORT=8080

EXPOSE 8080

ENTRYPOINT ["python", "src/main.py"]
