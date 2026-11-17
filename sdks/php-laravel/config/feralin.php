<?php

declare(strict_types=1);

return [
    // Yalnız pk_ anahtarı. Anahtar veya adres boşsa entegrasyon kapalıdır, olay üretilmez.
    'project_key' => env('FERALIN_PROJECT_KEY'),
    'collect_url' => env('FERALIN_COLLECT_URL'),

    // Feralin\Laravel\ConsentResolver uygulayan sınıf. Yoksa izin yok sayılır, olay üretilmez.
    // config:cache uyumu için closure değil sınıf adı verilir.
    'consent_resolver' => null,

    // Feralin\Laravel\IdentityResolver uygulayan sınıf (isteğe bağlı). E-posta veya telefon döndürmeyin.
    'identity_resolver' => null,

    // page_url (yol), referrer (yalnız origin) ve locale eklensin. Yolda kişisel veri varsa kapatın.
    'include_context' => true,

    // Feralin\Client seçenekleri: batchSize, queueLimit, timeoutSeconds.
    'client' => [],
];
