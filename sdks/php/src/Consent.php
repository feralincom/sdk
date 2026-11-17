<?php

declare(strict_types=1);

namespace Feralin;

/** UTP v1 izin nesnesi. Karar müşteri uygulamasından geçirilir; verilmeyen alan gönderilmez. */
final class Consent
{
    public function __construct(
        public readonly bool $analytics,
        public readonly ?bool $advertising = null,
        public readonly ?bool $personalization = null,
        public readonly ?bool $sessionReplay = null,
    ) {
    }

    /** @return array<string, bool> */
    public function toArray(): array
    {
        $out = ['analytics' => $this->analytics];
        if ($this->advertising !== null) {
            $out['advertising'] = $this->advertising;
        }
        if ($this->personalization !== null) {
            $out['personalization'] = $this->personalization;
        }
        if ($this->sessionReplay !== null) {
            $out['session_replay'] = $this->sessionReplay;
        }
        return $out;
    }
}
