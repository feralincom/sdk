<?php
/**
 * Genel sayfalara Web SDK'yı ekler. İzin kararı bekleniyorsa olay üretilmez; yönetici ve önizleme sayfalarında yüklenmez.
 *
 * @package Feralin
 */

defined( 'ABSPATH' ) || exit;

/** Ön yüz betiği. */
final class Feralin_Frontend {
	/** Kancaları bağlar. */
	public static function register(): void {
		add_action( 'wp_enqueue_scripts', array( self::class, 'enqueue' ) );
	}

	/** Betiği ve başlangıç kodunu ekler. */
	public static function enqueue(): void {
		$settings = Feralin_Settings::get();
		if ( ! $settings['frontend_enabled'] || '' === $settings['project_key'] || '' === $settings['collect_url'] || is_preview() ) {
			return;
		}
		$file = FERALIN_PLUGIN_DIR . 'assets/feralin.iife.js';
		if ( ! file_exists( $file ) ) {
			return;
		}
		wp_enqueue_script(
			'feralin-web',
			plugins_url( 'assets/feralin.iife.js', FERALIN_PLUGIN_FILE ),
			array(),
			FERALIN_PLUGIN_VERSION,
			array(
				'in_footer' => true,
				'strategy'  => 'defer',
			)
		);
		wp_add_inline_script( 'feralin-web', self::init_script( $settings ), 'after' );
	}

	/**
	 * Başlangıç kodu. Karar yoksa consent verilmez: SDK izin bekler, olay üretmez, depoya yazmaz.
	 *
	 * @param array{project_key: string, collect_url: string} $settings Ayarlar.
	 */
	private static function init_script( array $settings ): string {
		$config = wp_json_encode(
			array(
				'projectKey' => $settings['project_key'],
				'collectUrl' => $settings['collect_url'],
			),
			JSON_UNESCAPED_SLASHES
		);
		return <<<JS
(function () {
  if (!window.feralin) return;
  var config = {$config};
  function fromApi() {
    if (typeof window.wp_has_consent !== "function") return null;
    return { analytics: !!window.wp_has_consent("statistics"), advertising: !!window.wp_has_consent("marketing") };
  }
  var consent = fromApi();
  if (consent) config.consent = consent;
  window.feralin.initialize(config);
  document.addEventListener("wp_listen_for_consent_change", function () {
    var next = fromApi();
    if (next) window.feralin.setConsent(next);
  });
})();
JS;
	}
}
