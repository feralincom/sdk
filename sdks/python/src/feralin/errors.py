"""SDK hata sınıfları. Yapılandırma ve doğrulama hataları ValueError türevidir; teslim hataları
FlushResult.error içinde döner (flush() fırlatmaz; arka plan iş parçacığı için güvenli)."""

from __future__ import annotations


class FeralinError(Exception):
    """Tüm SDK hatalarının tabanı."""


class ConfigurationError(FeralinError, ValueError):
    """Geçersiz proje anahtarı, collect_url veya seçenek."""


class InvalidEventError(FeralinError, ValueError):
    """event_name, properties veya kimlik alanı UTP v1 kurallarına uymuyor."""


class ClientClosedError(FeralinError, RuntimeError):
    """close() sonrası track()/flush() çağrıldı."""


class DeliveryError(FeralinError):
    """Toplayıcıya gönderim hatası; status 0 ise ağ hatasıdır."""

    def __init__(self, message: str, *, status: int = 0, detail: str = "") -> None:
        super().__init__(message)
        self.status = status
        self.detail = detail


class RejectedError(DeliveryError):
    """4xx (429 hariç): batch kalıcı olarak reddedildi, olaylar kuyruktan atıldı."""


class TemporaryError(DeliveryError):
    """5xx, 429 veya ağ hatası: olaylar kuyrukta tutuldu, aynı Idempotency-Key ile yeniden denenecek."""
