import 'package:feralin_flutter/src/core/event_json.dart';
import 'package:feralin_flutter/src/core/revenue_event.dart';
import 'package:feralin_flutter/src/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// F5-E04-T01: trackRevenue sözleşmesi; verified düşer, sözleşme dışı girdi olay üretmez, motor olayı taşır.
void main() {
  test('sözleşme alanları kurulur ve verified düşer', () {
    final props = revenueProperties(
      const RevenueInput(
        transactionId: 'ord_1',
        amountMinor: 4999,
        currency: 'TRY',
        productId: 'pro',
        purchaseType: PurchaseType.subscriptionStart,
        receipt: Receipt(ReceiptProvider.stripe, 'tok_1'),
        properties: {'verified': true, 'receipt_digest': 'x', 'plan': 'pro'},
      ),
    );
    expect(props, isNotNull);
    expect(props!['transaction_id'], 'ord_1');
    expect(props['amount_minor'], 4999);
    expect(props['currency'], 'TRY');
    expect(props['quantity'], 1);
    expect(props['purchase_type'], 'subscription_start');
    expect(props['product_id'], 'pro');
    expect(props['plan'], 'pro');
    expect(props['receipt'], {'provider': 'stripe', 'token': 'tok_1'});
    expect(props.containsKey('verified'), isFalse);
    expect(props.containsKey('receipt_digest'), isFalse);
    final clean = sanitizeProperties(props);
    expect(clean['amount_minor'], 4999);
    expect(clean.containsKey('verified'), isFalse);
  });

  test('sözleşme dışı girdi olay üretmez', () {
    const bad = [
      RevenueInput(transactionId: '', amountMinor: 1, currency: 'TRY'),
      RevenueInput(transactionId: 't', amountMinor: -1, currency: 'TRY'),
      RevenueInput(
        transactionId: 't',
        amountMinor: maxAmountMinor + 1,
        currency: 'TRY',
      ),
      RevenueInput(transactionId: 't', amountMinor: 1, currency: 'try'),
      RevenueInput(
        transactionId: 't',
        amountMinor: 1,
        currency: 'TRY',
        quantity: -1,
      ),
      RevenueInput(
        transactionId: 't',
        amountMinor: 1,
        currency: 'TRY',
        productId: '',
      ),
      RevenueInput(
        transactionId: 't',
        amountMinor: 1,
        currency: 'TRY',
        receipt: Receipt(ReceiptProvider.apple, ''),
      ),
      RevenueInput(
        transactionId: 't',
        amountMinor: 1,
        currency: 'TRY',
        purchaseType: PurchaseType.subscriptionCancel,
      ),
    ];
    for (final input in bad) {
      expect(revenueProperties(input), isNull, reason: input.transactionId);
    }
  });

  test('motor feralin_purchase olayını tel üzerinde taşır, verified yoktur', () async {
    final h = Harness();
    final sdk = await h.start(granted);
    final props = revenueProperties(
      const RevenueInput(
        transactionId: 'ord_2',
        amountMinor: 100,
        currency: 'USD',
        properties: {'verified': true},
      ),
    );
    expect(sdk.track(revenueEventName, props), isNotNull);
    await sdk.settle();
    await sdk.flush();
    await sdk.settle();
    // İlk açılış olayı da gider; gelir olayı adıyla seçilir.
    final event = h.sentEvents.firstWhere(
      (e) => e['event_name'] == revenueEventName,
    );
    expect(event['event_name'], revenueEventName);
    expect(event.containsKey('verified'), isFalse);
    final sent = event['properties']! as Map<String, Object?>;
    expect(sent['amount_minor'], 100);
    expect(sent.containsKey('verified'), isFalse);
  });
}

const granted = Consent(analytics: true);
