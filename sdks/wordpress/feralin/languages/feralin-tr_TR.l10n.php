<?php
/**
 * WordPress 6.5+ PHP çeviri dosyası (Türkçe).
 *
 * @package Feralin
 */

return array(
	'domain'   => 'feralin',
	'language' => 'tr_TR',
	'messages' => array(
		'Connection'                 => 'Bağlantı',
		'Project public key'         => 'Proje public anahtarı',
		'Collector URL'              => 'Toplayıcı adresi',
		'Page tracking'              => 'Sayfa izleme',
		'WooCommerce order events'   => 'WooCommerce sipariş olayları',
		'Feralin'                    => 'Feralin',
		'Secret keys cannot be used here. Enter the project public key (pk_).' => 'Gizli anahtar burada kullanılamaz. Proje public anahtarını (pk_) girin.',
		'The project public key must start with pk_.' => 'Proje public anahtarı pk_ ile başlamalıdır.',
		'Enter a valid collector URL.' => 'Geçerli bir toplayıcı adresi girin.',
		'No event is produced without visitor consent. Consent is read from the WP Consent API; if your site uses another consent tool, call feralin.setConsent from it.' => 'Ziyaretçi izni olmadan olay üretilmez. İzin WP Consent API üzerinden okunur; sitenizde başka bir izin aracı varsa oradan feralin.setConsent çağırın.',
		'Load the Web SDK on public pages' => 'Web SDK genel sayfalarda yüklensin',
		'Send a server event when an order is completed, only with consent recorded at checkout' => 'Sipariş tamamlanınca sunucu olayı gönderilsin; yalnız ödeme anında kaydedilen izinle',
		'Feralin: the bundled SDK files are missing. Build the plugin with sdks/wordpress/scripts/build.mjs.' => 'Feralin: paketlenmiş SDK dosyaları eksik. Eklentiyi sdks/wordpress/scripts/build.mjs ile derleyin.',
	),
);
