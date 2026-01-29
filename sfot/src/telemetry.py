"""
OpenTelemetry instrumentation for SFOT pipeline

This module provides tracing, metrics, and logging for the SFOT processing pipeline.
"""

import os
import logging
from typing import Optional, Dict, Any
from contextlib import contextmanager

from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource, SERVICE_NAME, SERVICE_VERSION
from opentelemetry.semconv.resource import ResourceAttributes
from opentelemetry.trace import Status, StatusCode
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

# Logging imports
from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter

# Global instances
_tracer: Optional[trace.Tracer] = None
_meter: Optional[metrics.Meter] = None
_logger_provider: Optional[LoggerProvider] = None
_metrics: Dict[str, Any] = {}
_initialized: bool = False


def init_telemetry(
    service_name: str = "sfot",
    service_version: str = "1.0.0",
    environment: str = "production"
) -> bool:
    """
    Initialize OpenTelemetry with OTLP exporters for Grafana Cloud.

    Returns True if telemetry was initialized, False if disabled.
    """
    global _tracer, _meter, _logger_provider, _metrics, _initialized

    if _initialized:
        return True

    # Check if OTLP endpoint is configured
    otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not otlp_endpoint:
        logging.warning("OTEL_EXPORTER_OTLP_ENDPOINT not set, telemetry disabled")
        return False

    try:
        # Create resource with service info
        resource = Resource.create({
            SERVICE_NAME: service_name,
            SERVICE_VERSION: service_version,
            ResourceAttributes.DEPLOYMENT_ENVIRONMENT: environment,
        })

        # Setup tracing
        trace_provider = TracerProvider(resource=resource)
        trace_provider.add_span_processor(
            BatchSpanProcessor(OTLPSpanExporter())
        )
        trace.set_tracer_provider(trace_provider)
        _tracer = trace.get_tracer(service_name, service_version)

        # Setup metrics
        metric_reader = PeriodicExportingMetricReader(
            OTLPMetricExporter(),
            export_interval_millis=60000  # Export every 60s
        )
        meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
        metrics.set_meter_provider(meter_provider)
        _meter = metrics.get_meter(service_name, service_version)

        # Setup logging - exports Python logs to Loki via OTLP
        _logger_provider = LoggerProvider(resource=resource)
        _logger_provider.add_log_record_processor(
            BatchLogRecordProcessor(OTLPLogExporter())
        )
        set_logger_provider(_logger_provider)

        # Add OTLP handler to root logger to capture all logs
        # This handler automatically includes trace context (trace_id, span_id)
        otel_handler = LoggingHandler(
            level=logging.INFO,
            logger_provider=_logger_provider
        )
        logging.getLogger().addHandler(otel_handler)

        # Create metrics instruments
        _create_metrics()

        _initialized = True
        logging.info(f"OpenTelemetry initialized: endpoint={otlp_endpoint}")
        return True

    except Exception as e:
        logging.error(f"Failed to initialize OpenTelemetry: {e}")
        return False


def _create_metrics():
    """Create all metric instruments"""
    global _metrics

    # Counters
    _metrics["frames_processed"] = _meter.create_counter(
        "sfot.frames.processed",
        description="Total frames processed",
        unit="1"
    )

    _metrics["matchups_detected"] = _meter.create_counter(
        "sfot.matchups.detected",
        description="Total matchup screens detected",
        unit="1"
    )

    _metrics["chunks_completed"] = _meter.create_counter(
        "sfot.chunks.completed",
        description="Total chunks completed",
        unit="1"
    )

    _metrics["chunks_failed"] = _meter.create_counter(
        "sfot.chunks.failed",
        description="Total chunks failed",
        unit="1"
    )

    _metrics["detections_uploaded"] = _meter.create_counter(
        "sfot.detections.uploaded",
        description="Total detections uploaded to Supabase",
        unit="1"
    )

    # Detection funnel counters
    _metrics["emblem_not_found"] = _meter.create_counter(
        "sfot.emblem.not_found",
        description="Frames where no emblem was detected",
        unit="1"
    )

    _metrics["right_edge_failed"] = _meter.create_counter(
        "sfot.right_edge.failed",
        description="Frames where right edge detection failed",
        unit="1"
    )

    _metrics["ocr_empty"] = _meter.create_counter(
        "sfot.ocr.empty",
        description="OCR extractions that returned no text",
        unit="1"
    )

    _metrics["ocr_invalid_username"] = _meter.create_counter(
        "sfot.ocr.invalid_username",
        description="OCR extractions rejected by username validation",
        unit="1"
    )

    _metrics["frames_skipped"] = _meter.create_counter(
        "sfot.frames.skipped",
        description="Frames skipped (queue full or interval)",
        unit="1"
    )

    _metrics["queue_overflow"] = _meter.create_counter(
        "sfot.queue.overflow",
        description="Frame queue overflow events",
        unit="1"
    )

    _metrics["errors"] = _meter.create_counter(
        "sfot.errors",
        description="Categorized errors by component and type",
        unit="1"
    )

    # Histograms
    _metrics["ocr_confidence"] = _meter.create_histogram(
        "sfot.ocr.confidence",
        description="OCR confidence score distribution",
        unit="1"
    )

    _metrics["emblem_confidence"] = _meter.create_histogram(
        "sfot.emblem.confidence",
        description="Emblem detection confidence distribution",
        unit="1"
    )

    _metrics["right_edge_confidence"] = _meter.create_histogram(
        "sfot.right_edge.confidence",
        description="Right edge detection confidence distribution",
        unit="1"
    )

    _metrics["processing_duration"] = _meter.create_histogram(
        "sfot.chunk.duration",
        description="Chunk processing duration",
        unit="ms"
    )

    _metrics["frame_processing_rate"] = _meter.create_histogram(
        "sfot.frames.rate",
        description="Frame processing rate (FPS)",
        unit="1/s"
    )

    # Upload duration histogram (meaningful because it's a discrete operation)
    _metrics["upload_duration"] = _meter.create_histogram(
        "sfot.upload.duration",
        description="Supabase batch upload duration",
        unit="ms"
    )

    # Gauges (using UpDownCounter as proxy)
    _metrics["queue_depth"] = _meter.create_up_down_counter(
        "sfot.queue.depth",
        description="Current frame queue depth",
        unit="1"
    )


def get_tracer() -> Optional[trace.Tracer]:
    """Get the configured tracer"""
    return _tracer


def get_meter() -> Optional[metrics.Meter]:
    """Get the configured meter"""
    return _meter


def record_counter(name: str, value: int = 1, attributes: Dict[str, str] = None):
    """Record a counter metric"""
    if name in _metrics:
        _metrics[name].add(value, attributes or {})


def record_histogram(name: str, value: float, attributes: Dict[str, str] = None):
    """Record a histogram metric"""
    if name in _metrics:
        _metrics[name].record(value, attributes or {})


def record_gauge(name: str, delta: int, attributes: Dict[str, str] = None):
    """Record a gauge metric (using UpDownCounter)"""
    if name in _metrics:
        _metrics[name].add(delta, attributes or {})


@contextmanager
def create_span(
    name: str,
    attributes: Dict[str, Any] = None,
    kind: trace.SpanKind = trace.SpanKind.INTERNAL
):
    """
    Context manager to create and manage a span.

    Usage:
        with create_span("process_frame", {"frame.timestamp": 12345}) as span:
            # Do work
            if span:
                span.set_attribute("result", "success")
    """
    if _tracer is None:
        yield None
        return

    with _tracer.start_as_current_span(name, kind=kind) as span:
        if attributes:
            for key, value in attributes.items():
                if value is not None:  # Skip None values
                    span.set_attribute(key, value)
        try:
            yield span
        except Exception as e:
            span.set_status(Status(StatusCode.ERROR, str(e)))
            span.record_exception(e)
            raise


def extract_trace_context(headers: Dict[str, str]) -> Optional[trace.Context]:
    """
    Extract trace context from incoming headers (for trace propagation).

    Used to continue a trace from GitHub Actions (via TRACEPARENT env var).
    """
    propagator = TraceContextTextMapPropagator()
    return propagator.extract(carrier=headers)


def inject_trace_context(headers: Dict[str, str]) -> Dict[str, str]:
    """Inject trace context into outgoing headers"""
    propagator = TraceContextTextMapPropagator()
    propagator.inject(carrier=headers)
    return headers


def get_current_trace_id() -> Optional[str]:
    """Get the current trace ID if available"""
    span = trace.get_current_span()
    if span and span.is_recording():
        return format(span.get_span_context().trace_id, '032x')
    return None


def get_current_span_id() -> Optional[str]:
    """Get the current span ID if available"""
    span = trace.get_current_span()
    if span and span.is_recording():
        return format(span.get_span_context().span_id, '016x')
    return None


def add_span_event(name: str, attributes: Dict[str, Any] = None):
    """Add an event to the current span"""
    span = trace.get_current_span()
    if span and span.is_recording():
        span.add_event(name, attributes=attributes or {})


def set_span_attribute(key: str, value: Any):
    """Set an attribute on the current span"""
    span = trace.get_current_span()
    if span and span.is_recording() and value is not None:
        span.set_attribute(key, value)


def set_span_error(error: Exception):
    """Mark the current span as error"""
    span = trace.get_current_span()
    if span and span.is_recording():
        span.set_status(Status(StatusCode.ERROR, str(error)))
        span.record_exception(error)


def shutdown_telemetry(timeout_millis: int = 30000):
    """
    Flush and shutdown telemetry providers.

    MUST be called before process exit to ensure all spans/metrics/logs are exported.
    """
    global _initialized, _logger_provider

    if not _initialized:
        return

    try:
        # Flush and shutdown logger provider FIRST (so final logs are captured)
        if _logger_provider:
            if hasattr(_logger_provider, 'force_flush'):
                _logger_provider.force_flush(timeout_millis)
            if hasattr(_logger_provider, 'shutdown'):
                _logger_provider.shutdown()

        # Flush and shutdown trace provider
        trace_provider = trace.get_tracer_provider()
        if hasattr(trace_provider, 'force_flush'):
            trace_provider.force_flush(timeout_millis)
        if hasattr(trace_provider, 'shutdown'):
            trace_provider.shutdown()

        # Flush and shutdown meter provider
        meter_provider = metrics.get_meter_provider()
        if hasattr(meter_provider, 'force_flush'):
            meter_provider.force_flush(timeout_millis)
        if hasattr(meter_provider, 'shutdown'):
            meter_provider.shutdown()

        # Log after shutdown since the handler is already removed
        print("OpenTelemetry shutdown complete")
        _initialized = False

    except Exception as e:
        print(f"Error during telemetry shutdown: {e}")
