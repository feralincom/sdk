<?php

declare(strict_types=1);

namespace Feralin;

/**
 * Hata fırtınası sınırı: pencere başına en çok `maxEvents` olay, aynı parmak izi için en çok `maxPerFingerprint`; örnekleme
 * `sampleRate` (0..1). Sayılar Android SDK'sıyla aynıdır (20 ve 3); sunucu süreci uzun yaşadığından süreç ömrü yerine 60 saniyelik
 * pencerede sayılır.
 */
final class ErrorLimiter
{
    private int $windowStartMs = 0;
    private int $total = 0;
    /** @var array<string, int> */
    private array $perFingerprint = [];
    private float $sampleRate;

    public function __construct(
        private readonly int $maxEvents = 20,
        private readonly int $maxPerFingerprint = 3,
        float $sampleRate = 1.0,
        private readonly int $windowMs = 60000,
    ) {
        $this->sampleRate = max(0.0, min(1.0, $sampleRate));
    }

    /** @param float $random 0..1 rastgele değer (örnekleme için) */
    public function allow(string $fingerprint, int $nowMs, float $random): bool
    {
        if ($nowMs - $this->windowStartMs >= $this->windowMs || $nowMs < $this->windowStartMs) {
            $this->windowStartMs = $nowMs;
            $this->total = 0;
            $this->perFingerprint = [];
        }
        if ($this->total >= $this->maxEvents) {
            return false;
        }
        if ($this->sampleRate < 1.0 && $random >= $this->sampleRate) {
            return false;
        }
        $seen = $this->perFingerprint[$fingerprint] ?? 0;
        if ($seen >= $this->maxPerFingerprint) {
            return false;
        }
        $this->perFingerprint[$fingerprint] = $seen + 1;
        $this->total++;
        return true;
    }
}
