FROM python:3.12-slim
RUN pip install --no-cache-dir pyyaml
# docker CLI so we can stream logs + send SIGHUP
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg ca-certificates \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli=5:29.6.0-1~debian.12~bookworm \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY cert_pin_watcher.py /app/cert_pin_watcher.py
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python -c "import os; os.kill(1, 0)" || exit 1
CMD ["python", "-u", "/app/cert_pin_watcher.py"]
