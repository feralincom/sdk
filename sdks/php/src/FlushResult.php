<?php

declare(strict_types=1);

namespace Feralin;

/** Gönderim sonucu; hata fırlatılmaz, durum buradan okunur. Durum 0: istek yapılmadı veya ağ hatası. */
final class FlushResult
{
    public function __construct(
        public readonly int $sent = 0,
        public readonly int $accepted = 0,
        public readonly int $rejected = 0,
        public readonly int $status = 0,
        public readonly int $retained = 0,
        public readonly ?string $batchId = null,
    ) {
    }
}
