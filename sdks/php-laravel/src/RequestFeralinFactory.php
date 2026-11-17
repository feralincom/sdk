<?php

declare(strict_types=1);

namespace Feralin\Laravel;

use Feralin\Client;
use Feralin\Consent;
use Illuminate\Http\Request;
use Throwable;

/** Çözümleyici hatası uygulamayı düşürmez: izin yok sayılır. IP, User-Agent ve çerez okunmaz, sorgu dizgisi gönderilmez. */
final class RequestFeralinFactory
{
    public function __construct(
        private readonly ?Client $client,
        private readonly ?ConsentResolver $consentResolver = null,
        private readonly ?IdentityResolver $identityResolver = null,
        private readonly bool $includeContext = true,
    ) {
    }

    public function forRequest(Request $request): RequestFeralin
    {
        try {
            $consent = $this->consentResolver?->resolve($request);
        } catch (Throwable) {
            $consent = null;
        }
        $consent ??= new Consent(false);

        $defaults = [];
        try {
            $identity = $this->identityResolver?->resolve($request) ?? [];
        } catch (Throwable) {
            $identity = [];
        }
        foreach (['userId', 'anonymousId', 'sessionId'] as $field) {
            if (isset($identity[$field]) && is_string($identity[$field]) && $identity[$field] !== '') {
                $defaults[$field] = $identity[$field];
            }
        }
        if ($this->includeContext && $consent->analytics) {
            $defaults['context'] = self::context($request);
        }
        return new RequestFeralin($this->client, $consent, $defaults);
    }

    /** @return array<string, string> */
    private static function context(Request $request): array
    {
        // url() sorgu dizgisini içermez; çekirdek referrer'ı origin'e indirir.
        $context = [];
        try {
            $context['page_url'] = $request->url();
        } catch (Throwable) {
            // Geçersiz Host başlığında Symfony Request fırlatır; istek bu yüzden düşmez, adres gönderilmez.
        }
        $referrer = $request->headers->get('referer');
        if (is_string($referrer) && $referrer !== '') {
            $context['referrer'] = $referrer;
        }
        $language = $request->headers->get('accept-language');
        if (is_string($language)) {
            $first = trim(explode(';', explode(',', $language)[0])[0]);
            if ($first !== '' && $first !== '*') {
                $context['locale'] = $first;
            }
        }
        return $context;
    }
}
