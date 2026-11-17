"""Feralin FastAPI ara katmanı: `feralin` çekirdeği üstünde istek başına izin ve kimlik geçirme."""

from ._core import ConsentClientPool, RequestFeralin, clean_context
from .middleware import FeralinMiddleware, get_feralin

__version__ = "0.1.0"

__all__ = ["ConsentClientPool", "FeralinMiddleware", "RequestFeralin", "clean_context", "get_feralin", "__version__"]
