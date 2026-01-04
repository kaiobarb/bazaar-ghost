# syntax=docker/dockerfile:1.7
FROM python:3.11-slim-bookworm

# Keep apt quiet & lean; keep pip quick and cached
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1

# OS deps (cache apt metadata; no dev pkgs)
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
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

# Pre-download PaddleOCR mobile models (smallest footprint)
RUN python -c "from paddleocr import PaddleOCR; PaddleOCR(lang='en', text_detection_model_name='PP-OCRv5_mobile_det', text_recognition_model_name='en_PP-OCRv5_mobile_rec', use_doc_orientation_classify=False, use_doc_unwarping=False, use_textline_orientation=False); print('PaddleOCR mobile models downloaded')"

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