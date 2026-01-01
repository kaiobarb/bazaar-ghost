# syntax=docker/dockerfile:1.7
FROM python:3.11-slim-bookworm

# Keep apt quiet & lean; keep pip quick and cached
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    TESSDATA_PREFIX=/usr/share/tessdata

# OS deps (cache apt metadata; no dev pkgs)
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        tesseract-ocr \
        libgl1 \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender1 \
        libgomp1 \
        wget \
        git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

# Faster pip installs via BuildKit cache mount, prefer wheels
RUN --mount=type=cache,target=/root/.cache/pip \
      python -m pip install --upgrade pip \
   && python -m pip install --prefer-binary -r requirements.txt \
   && pip install opentelemetry-distro opentelemetry-exporter-otlp \
   && opentelemetry-bootstrap --action=install

# Download Legacy-compatible Tesseract traineddata
# The tessdata repo contains combined Legacy+LSTM models
RUN mkdir -p /usr/share/tessdata \
    && wget -q https://github.com/tesseract-ocr/tessdata/raw/main/eng.traineddata \
    -O /usr/share/tessdata/eng.traineddata \
    && chmod 644 /usr/share/tessdata/eng.traineddata

# Copy the rest (use --chown to avoid a later chown layer)
COPY --chown=1000:1000 config.yaml .
COPY --chown=1000:1000 src/ ./src/
COPY --chown=1000:1000 templates/ ./templates/

# Create health file and set up user permissions
RUN echo "ok" > /app/health && \
    useradd -m -u 1000 sfot && \
    chown -R sfot:sfot /app

# Switch to non-root user
USER sfot
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD [ -f /app/health ] || exit 1

ENTRYPOINT ["python", "-u", "src/sfot.py"]