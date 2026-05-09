FROM python:3.12-slim

# Non-root user for security
RUN useradd -m -u 1001 appuser

WORKDIR /app
COPY src/main.py .

# Build-time arg injected by CI (git SHA)
ARG BUILD_VERSION=dev
ENV BUILD_VERSION=${BUILD_VERSION}

USER appuser
EXPOSE 8080

CMD ["python", "main.py"]
