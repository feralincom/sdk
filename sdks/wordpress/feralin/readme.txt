=== Feralin ===
Tags: analytics, attribution, woocommerce, privacy
Requires at least: 6.5
Tested up to: 6.5
Requires PHP: 8.1
Stable tag: 0.1.0
License: MIT

Consent-first analytics and WooCommerce order events for Feralin.

== Description ==

Sends page views through the Feralin Web SDK and completed WooCommerce orders as server events. No event is produced without visitor consent. Consent comes from the WP Consent API or from your own consent tool through feralin.setConsent.

Completed orders are sent as a feralin_purchase revenue declaration: transaction id woo:order:<id>, amount as an integer in the currency minor unit, currency, quantity and order id. Refunds are not sent by the plugin; they reach the ledger through the WooCommerce webhook connection. Customer name, email and address are not sent. The WordPress user id is replaced with a site-salted pseudonym.

This plugin sends data to the collector URL you configure. Nothing is sent until you enter a project public key and a collector URL and enable tracking.

Status: not published. This code has not been run yet.
