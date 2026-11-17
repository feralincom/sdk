<?php
/**
 * Ayarlar sayfası. Yalnız public proje anahtarı saklanır; sk_ ile başlayan gizli anahtar reddedilir.
 *
 * @package Feralin
 */

defined( 'ABSPATH' ) || exit;

/** Settings API kaydı, doğrulama ve okuma. */
final class Feralin_Settings {
	private const OPTION = 'feralin_settings';

	/** Yönetici kancalarını bağlar. */
	public static function register(): void {
		add_action( 'admin_init', array( self::class, 'register_settings' ) );
		add_action( 'admin_menu', array( self::class, 'register_menu' ) );
		add_action( 'admin_notices', array( self::class, 'vendor_notice' ) );
	}

	/**
	 * Geçerli ayarları varsayılanlarla döndürür. Takip varsayılan olarak kapalıdır.
	 *
	 * @return array{project_key: string, collect_url: string, frontend_enabled: bool, woocommerce_enabled: bool}
	 */
	public static function get(): array {
		$saved = get_option( self::OPTION, array() );
		$saved = is_array( $saved ) ? $saved : array();
		return array(
			'project_key'         => (string) ( $saved['project_key'] ?? '' ),
			'collect_url'         => (string) ( $saved['collect_url'] ?? '' ),
			'frontend_enabled'    => ! empty( $saved['frontend_enabled'] ),
			'woocommerce_enabled' => ! empty( $saved['woocommerce_enabled'] ),
		);
	}

	/** Ayar ve alanları kaydeder. */
	public static function register_settings(): void {
		register_setting(
			'feralin',
			self::OPTION,
			array(
				'type'              => 'array',
				'sanitize_callback' => array( self::class, 'sanitize' ),
				'default'           => array(),
			)
		);
		add_settings_section( 'feralin_main', __( 'Connection', 'feralin' ), '__return_false', 'feralin' );
		add_settings_field( 'project_key', __( 'Project public key', 'feralin' ), array( self::class, 'field_project_key' ), 'feralin', 'feralin_main' );
		add_settings_field( 'collect_url', __( 'Collector URL', 'feralin' ), array( self::class, 'field_collect_url' ), 'feralin', 'feralin_main' );
		add_settings_field( 'frontend_enabled', __( 'Page tracking', 'feralin' ), array( self::class, 'field_frontend' ), 'feralin', 'feralin_main' );
		add_settings_field( 'woocommerce_enabled', __( 'WooCommerce order events', 'feralin' ), array( self::class, 'field_woocommerce' ), 'feralin', 'feralin_main' );
	}

	/**
	 * Girdiyi doğrular. Geçersiz anahtar veya adres kaydedilmez.
	 *
	 * @param mixed $input Form verisi.
	 * @return array<string, mixed>
	 */
	public static function sanitize( $input ): array {
		$input   = is_array( $input ) ? $input : array();
		$current = self::get();
		$key     = isset( $input['project_key'] ) ? sanitize_text_field( wp_unslash( (string) $input['project_key'] ) ) : '';
		if ( str_starts_with( $key, 'sk_' ) ) {
			add_settings_error( self::OPTION, 'feralin_secret_key', __( 'Secret keys cannot be used here. Enter the project public key (pk_).', 'feralin' ) );
			$key = $current['project_key'];
		} elseif ( '' !== $key && ! preg_match( '/^pk_[A-Za-z0-9_-]{5,}$/D', $key ) ) {
			add_settings_error( self::OPTION, 'feralin_invalid_key', __( 'The project public key must start with pk_.', 'feralin' ) );
			$key = $current['project_key'];
		}
		$url = isset( $input['collect_url'] ) ? esc_url_raw( wp_unslash( (string) $input['collect_url'] ), array( 'https', 'http' ) ) : '';
		if ( '' !== $url && ! wp_http_validate_url( $url ) && ! str_starts_with( $url, 'http://127.0.0.1' ) && ! str_starts_with( $url, 'http://localhost' ) ) {
			add_settings_error( self::OPTION, 'feralin_invalid_url', __( 'Enter a valid collector URL.', 'feralin' ) );
			$url = $current['collect_url'];
		}
		return array(
			'project_key'         => $key,
			'collect_url'         => untrailingslashit( $url ),
			'frontend_enabled'    => ! empty( $input['frontend_enabled'] ),
			'woocommerce_enabled' => ! empty( $input['woocommerce_enabled'] ),
		);
	}

	/** Menü girdisi. */
	public static function register_menu(): void {
		add_options_page( 'Feralin', 'Feralin', 'manage_options', 'feralin', array( self::class, 'render_page' ) );
	}

	/** Ayarlar sayfası. */
	public static function render_page(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}
		echo '<div class="wrap"><h1>' . esc_html__( 'Feralin', 'feralin' ) . '</h1>';
		echo '<p>' . esc_html__( 'No event is produced without visitor consent. Consent is read from the WP Consent API; if your site uses another consent tool, call feralin.setConsent from it.', 'feralin' ) . '</p>';
		echo '<form method="post" action="options.php">';
		settings_fields( 'feralin' );
		do_settings_sections( 'feralin' );
		submit_button();
		echo '</form></div>';
	}

	/** Anahtar alanı. */
	public static function field_project_key(): void {
		printf(
			'<input type="text" class="regular-text" name="%1$s[project_key]" value="%2$s" autocomplete="off" />',
			esc_attr( self::OPTION ),
			esc_attr( self::get()['project_key'] )
		);
	}

	/** Toplayıcı adresi alanı. */
	public static function field_collect_url(): void {
		printf(
			'<input type="url" class="regular-text" name="%1$s[collect_url]" value="%2$s" placeholder="https://collect.example.com" />',
			esc_attr( self::OPTION ),
			esc_attr( self::get()['collect_url'] )
		);
	}

	/** Sayfa izleme seçeneği. */
	public static function field_frontend(): void {
		printf(
			'<label><input type="checkbox" name="%1$s[frontend_enabled]" value="1" %2$s /> %3$s</label>',
			esc_attr( self::OPTION ),
			checked( self::get()['frontend_enabled'], true, false ),
			esc_html__( 'Load the Web SDK on public pages', 'feralin' )
		);
	}

	/** Sipariş olayı seçeneği. */
	public static function field_woocommerce(): void {
		printf(
			'<label><input type="checkbox" name="%1$s[woocommerce_enabled]" value="1" %2$s /> %3$s</label>',
			esc_attr( self::OPTION ),
			checked( self::get()['woocommerce_enabled'], true, false ),
			esc_html__( 'Send a server event when an order is completed, only with consent recorded at checkout', 'feralin' )
		);
	}

	/** Paketlenmiş dosyalar yoksa açıkça uyarır; eklenti sessizce çalışmıyormuş gibi görünmez. */
	public static function vendor_notice(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}
		if ( ! file_exists( FERALIN_PLUGIN_DIR . 'assets/feralin.iife.js' ) || ! file_exists( FERALIN_PLUGIN_DIR . 'lib/feralin-php/Client.php' ) ) {
			echo '<div class="notice notice-error"><p>' . esc_html__( 'Feralin: the bundled SDK files are missing. Build the plugin with sdks/wordpress/scripts/build.mjs.', 'feralin' ) . '</p></div>';
		}
	}
}
