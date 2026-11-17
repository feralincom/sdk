<?php
/**
 * WooCommerce sipariş olayları. İzin ödeme anında siparişe yazılır; izin yoksa olay üretilmez. Müşteri adı, e-postası ve
 * adresi gönderilmez. Hiçbir hata sipariş akışını durdurmaz.
 *
 * Tamamlanan sipariş PHP SDK `trackRevenue` ile `feralin_purchase` gelir beyanı olarak gider (istemci beyanı, ESTIMATED).
 * İşlem kimliği sunucudaki WooCommerce webhook ayrıştırıcısıyla aynıdır (`woo:order:<id>`): webhook da bağlıysa defter aynı
 * siparişi ikinci kez saymaz ve webhook'tan gelen iade (`woo:refund:<id>:<iade>`) bu satın almaya bağlanır. SDK gelir
 * sözleşmesinde iade olayı yoktur; iadeler yalnız sunucu tarafı WooCommerce webhook'uyla deftere girer.
 *
 * @package Feralin
 */

defined( 'ABSPATH' ) || exit;

/** Sipariş kancaları ve WP-Cron ile yeniden deneme. */
final class Feralin_WooCommerce {
	private const PENDING_OPTION = 'feralin_pending_events';
	private const RETRY_HOOK     = 'feralin_retry_pending';
	private const MAX_PENDING    = 500;
	private const META_CONSENT   = '_feralin_consent';
	private const META_TRACKED   = '_feralin_tracked';
	private const MAX_QUANTITY   = 100000;
	// ISO 4217 küçük birim basamağı (varsayılan 2); sunucudaki WooCommerce webhook ayrıştırıcısıyla aynı listeler.
	private const ZERO_DECIMAL  = array( 'BIF', 'CLP', 'DJF', 'GNF', 'ISK', 'JPY', 'KMF', 'KRW', 'PYG', 'RWF', 'UGX', 'UYI', 'VND', 'VUV', 'XAF', 'XOF', 'XPF' );
	private const THREE_DECIMAL = array( 'BHD', 'IQD', 'JOD', 'KWD', 'LYD', 'OMR', 'TND' );

	/** Kancaları bağlar. */
	public static function register(): void {
		add_action( self::RETRY_HOOK, array( self::class, 'retry_pending' ) );
		if ( ! class_exists( 'WooCommerce' ) || ! Feralin_Settings::get()['woocommerce_enabled'] ) {
			return;
		}
		add_action( 'woocommerce_checkout_order_created', array( self::class, 'record_consent' ) );
		// Blok tabanlı ödeme sayfası klasik kancayı çağırmaz.
		add_action( 'woocommerce_store_api_checkout_order_processed', array( self::class, 'record_consent' ) );
		add_action( 'woocommerce_order_status_completed', array( self::class, 'order_completed' ) );
	}

	/** Eklenti kapanınca zamanlanmış denemeyi kaldırır. */
	public static function unschedule(): void {
		wp_clear_scheduled_hook( self::RETRY_HOOK );
	}

	/**
	 * Ödeme anındaki izni siparişe yazar. WP Consent API yoksa `feralin_checkout_consent` süzgeciyle verilmelidir.
	 *
	 * @param WC_Order $order Sipariş.
	 */
	public static function record_consent( $order ): void {
		try {
			$consent = function_exists( 'wp_has_consent' )
				? array(
					'analytics'   => (bool) wp_has_consent( 'statistics' ),
					'advertising' => (bool) wp_has_consent( 'marketing' ),
				)
				: null;
			$consent = apply_filters( 'feralin_checkout_consent', $consent, $order );
			if ( is_array( $consent ) ) {
				$order->update_meta_data(
					self::META_CONSENT,
					array(
						'analytics'   => ! empty( $consent['analytics'] ),
						'advertising' => ! empty( $consent['advertising'] ),
					)
				);
				$order->save_meta_data();
			}
		} catch ( Throwable $error ) {
			self::log_error( $error );
		}
	}

	/**
	 * Sipariş tamamlanınca bir kez `feralin_purchase` gönderir. Tutar ya da para birimi sözleşmeye uymazsa olay üretilmez.
	 *
	 * @param int $order_id Sipariş kimliği.
	 */
	public static function order_completed( $order_id ): void {
		try {
			$order = wc_get_order( $order_id );
			if ( ! $order || $order->get_meta( self::META_TRACKED ) ) {
				return;
			}
			$stored = $order->get_meta( self::META_CONSENT );
			if ( ! is_array( $stored ) || empty( $stored['analytics'] ) ) {
				return;
			}
			$client = self::client();
			if ( null === $client ) {
				return;
			}
			$currency     = strtoupper( (string) $order->get_currency() );
			$amount_minor = self::amount_minor( $order->get_total(), $currency );
			if ( null === $amount_minor ) {
				return;
			}
			$item_count = max( 0, (int) $order->get_item_count() );
			$properties = array(
				'order_id'   => (string) $order->get_id(),
				'item_count' => $item_count,
				'source'     => 'woocommerce',
			);
			/**
			 * Süzgeç ek olay özelliklerini değiştirir. Tıklama kimliğini `fr_click` olarak buradan ekleyebilirsiniz; SDK reklam izni
			 * yoksa çıkarır. Kişisel veri eklemeyin. Gelir sözleşmesi alanları (transaction_id, amount_minor, currency, quantity,
			 * purchase_type) ve doğrulama alanları süzgeçle değiştirilemez.
			 */
			$properties = (array) apply_filters( 'feralin_order_event_properties', $properties, $order );
			$options    = array(
				'consent' => new Feralin\Consent( true, ! empty( $stored['advertising'] ) ),
			);
			$user_id    = (int) $order->get_user_id();
			if ( $user_id > 0 ) {
				// Ham WordPress kimliği yerine site tuzuyla türetilmiş takma ad.
				$options['userId'] = 'wp_' . substr( hash_hmac( 'sha256', (string) $user_id, wp_salt( 'auth' ) ), 0, 32 );
			}
			$event = $client->trackRevenue(
				array(
					'transactionId' => 'woo:order:' . $order->get_id(),
					'amountMinor'   => $amount_minor,
					'currency'      => $currency,
					'quantity'      => min( $item_count, self::MAX_QUANTITY ),
					'purchaseType'  => 'purchase',
					'properties'    => $properties,
				),
				$options
			);
			if ( null === $event ) {
				return;
			}
			$order->update_meta_data( self::META_TRACKED, gmdate( 'c' ) );
			$order->save_meta_data();
			self::deliver( $client );
		} catch ( Throwable $error ) {
			self::log_error( $error );
		}
	}

	/** WP-Cron: bekleyen olayları aynı event_id ile yeniden gönderir. */
	public static function retry_pending(): void {
		try {
			$pending = get_option( self::PENDING_OPTION, array() );
			delete_option( self::PENDING_OPTION );
			$client = self::client();
			if ( ! is_array( $pending ) || array() === $pending || null === $client ) {
				return;
			}
			// Olaylar ödeme anındaki izinle üretildi ve kendi consent alanlarını taşır; yeniden üretilmez.
			$client->importPending( array_values( array_filter( $pending, 'is_string' ) ) );
			self::deliver( $client );
		} catch ( Throwable $error ) {
			self::log_error( $error );
		}
	}

	/** Gönderir; geçici hatada kalanı autoload kapalı seçenekte saklar ve artan aralıkla cron kurar. */
	private static function deliver( Feralin\Client $client ): void {
		$result = $client->flush();
		if ( 0 === $result->retained ) {
			delete_option( 'feralin_retry_attempt' );
			return;
		}
		$pending = array_slice( $client->exportPending(), -self::MAX_PENDING );
		update_option( self::PENDING_OPTION, $pending, false );
		$attempt = (int) get_option( 'feralin_retry_attempt', 0 ) + 1;
		update_option( 'feralin_retry_attempt', $attempt, false );
		if ( ! wp_next_scheduled( self::RETRY_HOOK ) ) {
			// Geri çekilme: 1 dk, 2 dk, 4 dk… en çok 1 saat; jitter aynı dakikada yığılmayı önler.
			$delay = min( HOUR_IN_SECONDS, MINUTE_IN_SECONDS * ( 2 ** min( $attempt - 1, 6 ) ) ) + wp_rand( 0, 30 );
			wp_schedule_single_event( time() + $delay, self::RETRY_HOOK );
		}
	}

	/** SDK istemcisi; ayar veya paketlenmiş dosya eksikse null. */
	private static function client(): ?Feralin\Client {
		$settings = Feralin_Settings::get();
		if ( '' === $settings['project_key'] || '' === $settings['collect_url'] ) {
			return null;
		}
		$base = FERALIN_PLUGIN_DIR . 'lib/feralin-php/';
		if ( ! file_exists( $base . 'Client.php' ) ) {
			return null;
		}
		foreach ( array( 'Consent', 'EventRules', 'Revenue', 'FlushResult', 'Idempotency', 'Transport', 'StreamTransport', 'Client' ) as $file ) {
			require_once $base . $file . '.php';
		}
		return new Feralin\Client(
			$settings['project_key'],
			$settings['collect_url'],
			array(
				'flushOnShutdown' => false,
				'timeoutSeconds'  => 3.0,
				'consent'         => new Feralin\Consent( false ),
			)
		);
	}

	/**
	 * Sipariş toplamını ISO 4217 küçük birimine çevirir ("249.50" TRY → 24950). Negatif, sayı olmayan ya da sınır dışı tutar ve
	 * geçersiz para birimi null döner; olay üretilmez.
	 *
	 * @param mixed  $total    WooCommerce sipariş toplamı (metin ya da sayı).
	 * @param string $currency Üç harfli para birimi.
	 */
	private static function amount_minor( $total, string $currency ): ?int {
		if ( 1 !== preg_match( '/^[A-Z]{3}$/D', $currency ) ) {
			return null;
		}
		$text = is_string( $total ) ? trim( $total ) : ( is_int( $total ) || is_float( $total ) ? (string) $total : '' );
		if ( 1 !== preg_match( '/^\d{1,15}(\.\d+)?$/D', $text ) ) {
			return null;
		}
		$exponent = in_array( $currency, self::ZERO_DECIMAL, true ) ? 0 : ( in_array( $currency, self::THREE_DECIMAL, true ) ? 3 : 2 );
		// Basamağa yuvarlanmış metin üzerinden çevrilir; kayan nokta çarpımı (249.5 * 100) kuruş kaydırabilirdi.
		$minor = (int) str_replace( '.', '', number_format( (float) $text, $exponent, '.', '' ) );
		return $minor > Feralin\Revenue::MAX_AMOUNT_MINOR ? null : $minor;
	}

	/** Hata yalnız türüyle yazılır; anahtar veya sipariş verisi günlüğe girmez. */
	private static function log_error( Throwable $error ): void {
		if ( defined( 'WP_DEBUG' ) && WP_DEBUG ) {
			// phpcs:ignore WordPress.PHP.DevelopmentFunctions.error_log_error_log
			error_log( 'feralin: ' . get_class( $error ) );
		}
	}
}
