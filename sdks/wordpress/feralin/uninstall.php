<?php
/**
 * Eklenti silinince yalnız kendi seçeneklerini kaldırır; sipariş üzerindeki meta kayıtlarına dokunulmaz.
 *
 * @package Feralin
 */

defined( 'WP_UNINSTALL_PLUGIN' ) || exit;

delete_option( 'feralin_settings' );
delete_option( 'feralin_pending_events' );
