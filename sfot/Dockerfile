FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    ffmpeg \
    tesseract-ocr \
    tesseract-ocr-eng \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install streamlink separately (not available in apt for newer versions)
RUN pip install --no-cache-dir streamlink==7.1.3

# Set working directory
WORKDIR /app

# Copy requirements first (for better caching)
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy configuration
COPY config.yaml .

# Copy application source
COPY src/ ./src/

# Create templates directory
RUN mkdir -p templates

# Create non-root user
RUN useradd -m -u 1000 sfot && \
    chown -R sfot:sfot /app

# Switch to non-root user
USER sfot

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import sys; sys.path.append('/app/src'); from sfot import SFOTProcessor; print('healthy')" || exit 1

# Set Python to unbuffered mode
ENV PYTHONUNBUFFERED=1

# Entry point
ENTRYPOINT ["python", "-u", "src/sfot.py"]