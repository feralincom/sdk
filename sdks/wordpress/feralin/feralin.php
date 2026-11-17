<?php
/**
 * Plugin Name:       Feralin
 * Description:       Consent-first analytics and WooCommerce order events for Feralin.
 * Version:           0.1.0
 * Requires at least: 6.5
 * Requires PHP:      8.1
 * Author:            Feralin
 * License:           MIT
 * Text Domain:       feralin
 * Domain Path:       /languages
 *
 * @package Feralin
 */

defined( 'ABSPATH' ) || exit;

define( 'FERALIN_PLUGIN_VERSION', '0.1.0' );
define( 'FERALIN_PLUGIN_FILE', __FILE__ );
define( 'FERALIN_PLUGIN_DIR', plugin_dir_path( __FILE__ ) );

require_once FERALIN_PLUGIN_DIR . 'includes/class-feralin-settings.php';
require_once FERALIN_PLUGIN_DIR . 'includes/class-feralin-frontend.php';
require_once FERALIN_PLUGIN_DIR . 'includes/class-feralin-woocommerce.php';

add_action(
	'plugins_loaded',
	static function (): void {
		load_plugin_textdomain( 'feralin', false, dirname( plugin_basename( FERALIN_PLUGIN_FILE ) ) . '/languages' );
		Feralin_Settings::register();
		Feralin_Frontend::register();
		Feralin_WooCommerce::register();
	}
);

register_deactivation_hook( FERALIN_PLUGIN_FILE, array( 'Feralin_WooCommerce', 'unschedule' ) );
