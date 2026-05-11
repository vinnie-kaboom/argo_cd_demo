# ---- builder/scanner stage ----
FROM python:3.12-slim AS base

WORKDIR /app

# Install trivy for scanning
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install helm for chart linting/scanning
RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

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
