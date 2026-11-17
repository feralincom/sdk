<?php

declare(strict_types=1);

namespace Feralin\Symfony\EventSubscriber;

use Feralin\Client;
use Feralin\Consent;
use Feralin\Symfony\ConsentResolverInterface;
use Feralin\Symfony\IdentityResolverInterface;
use Feralin\Symfony\RequestFeralin;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpKernel\Event\RequestEvent;
use Symfony\Component\HttpKernel\Event\TerminateEvent;
use Symfony\Component\HttpKernel\KernelEvents;
use Throwable;

/**
 * Ana isteğe yüzeyi ekler, yanıt gönderildikten sonra kuyruğu boşaltır. Çözümleyici hatası uygulamayı düşürmez: izin yok
 * sayılır. IP, User-Agent ve çerez okunmaz, sorgu dizgisi gönderilmez.
 */
final class FeralinSubscriber implements EventSubscriberInterface
{
    public const ATTRIBUTE = '_feralin';

    public function __construct(
        private readonly Client $client,
        private readonly ?ConsentResolverInterface $consentResolver = null,
        private readonly ?IdentityResolverInterface $identityResolver = null,
        private readonly bool $includeContext = true,
    ) {
    }

    public static function getSubscribedEvents(): array
    {
        return [
            KernelEvents::REQUEST => ['onRequest', 64],
            KernelEvents::TERMINATE => 'onTerminate',
        ];
    }

    public function onRequest(RequestEvent $event): void
    {
        if ($event->isMainRequest()) {
            $event->getRequest()->attributes->set(self::ATTRIBUTE, $this->forRequest($event->getRequest()));
        }
    }

    public function onTerminate(TerminateEvent $event): void
    {
        $this->client->flush();
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
        // Sorgu dizgisi eklenmez; çekirdek referrer'ı origin'e indirir.
        $context = [];
        try {
            $context['page_url'] = $request->getSchemeAndHttpHost() . $request->getBaseUrl() . $request->getPathInfo();
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
