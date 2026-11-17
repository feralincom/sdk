"""Feralin UTP v1 server SDK (Python). Yalnız standart kütüphane; consent-first; at-least-once batch gönderimi."""

import logging as _logging

from .client import (
    DEFAULT_BATCH_SIZE,
    DEFAULT_FLUSH_INTERVAL,
    DEFAULT_QUEUE_LIMIT,
    MAX_BATCH_SIZE,
    PLATFORM,
    SDK_NAME,
    SDK_VERSION,
    Client,
)
from .error_capture import (
    ERROR_EVENT_NAME,
    ERROR_ORIGIN_HANDLED,
    ERROR_ORIGIN_MANUAL,
    ERROR_ORIGIN_UNCAUGHT,
    error_properties,
    scrub_error_message,
)
from .errors import (
    ClientClosedError,
    ConfigurationError,
    DeliveryError,
    FeralinError,
    InvalidEventError,
    RejectedError,
    TemporaryError,
)
from .events import AppInfo, Consent, Context, FlushResult, Screen, UtpEvent
from .profile import (
    GROUP_EVENT_NAME,
    MAX_PROFILE_PROPERTIES,
    USER_PROPERTIES_EVENT_NAME,
    is_pii_like_key,
    sanitize_profile_properties,
)
from .revenue import PURCHASE_TYPES, RECEIPT_PROVIDERS, REVENUE_EVENT_NAME, Receipt, revenue_properties
from .transport import Transport, urllib_transport
from .ulid import ULIDGenerator, is_ulid

__version__ = SDK_VERSION

# Kütüphane kuralı: uygulama logging yapılandırmadıysa SDK uyarıları stderr'e dökülmez.
_logging.getLogger("feralin").addHandler(_logging.NullHandler())

__all__ = [
    "AppInfo",
    "Client",
    "ClientClosedError",
    "ConfigurationError",
    "Consent",
    "Context",
    "DEFAULT_BATCH_SIZE",
    "DEFAULT_FLUSH_INTERVAL",
    "DEFAULT_QUEUE_LIMIT",
    "DeliveryError",
    "ERROR_EVENT_NAME",
    "ERROR_ORIGIN_HANDLED",
    "ERROR_ORIGIN_MANUAL",
    "ERROR_ORIGIN_UNCAUGHT",
    "FeralinError",
    "FlushResult",
    "GROUP_EVENT_NAME",
    "InvalidEventError",
    "MAX_BATCH_SIZE",
    "MAX_PROFILE_PROPERTIES",
    "PLATFORM",
    "PURCHASE_TYPES",
    "RECEIPT_PROVIDERS",
    "REVENUE_EVENT_NAME",
    "Receipt",
    "RejectedError",
    "SDK_NAME",
    "SDK_VERSION",
    "Screen",
    "TemporaryError",
    "Transport",
    "ULIDGenerator",
    "USER_PROPERTIES_EVENT_NAME",
    "UtpEvent",
    "__version__",
    "error_properties",
    "is_pii_like_key",
    "is_ulid",
    "revenue_properties",
    "sanitize_profile_properties",
    "scrub_error_message",
    "urllib_transport",
]
