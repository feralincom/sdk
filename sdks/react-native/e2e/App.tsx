// Emülatör testi uygulaması: scripts/e2e-emulator.mjs bunu temiz bir React Native projesine kopyalar. Akış gerçek JS → gerçek köprü
// → gerçek Android çekirdeği → gerçek services/collect. Sonuçlar logcat'e `RN_E2E {...}` satırları olarak yazılır, ağ geçişleri
// sağlık ucu yoklanarak betikle eşlenir. Anahtar test anahtarıdır, gerçek proje anahtarı değildir.
import React, {useEffect, useState} from 'react';
import {SafeAreaView, Text} from 'react-native';
import Feralin from '@feralin/react-native';

const COLLECT_URL = 'http://10.0.2.2:__COLLECT_PORT__';
const PROJECT_KEY = '__PROJECT_KEY__';

const report = (step: string, detail: object) => console.log(`RN_E2E ${JSON.stringify({step, ...detail})}`);
const wait = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));

async function reachable(): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1500);
    const response = await fetch(`${COLLECT_URL}/v1/health`, {signal: controller.signal});
    clearTimeout(timer);
    return response.ok;
  } catch {
    return false;
  }
}

async function until(expected: boolean, limitMs: number): Promise<boolean> {
  const started = Date.now();
  while (Date.now() - started < limitMs) {
    if ((await reachable()) === expected) {
      return true;
    }
    await wait(500);
  }
  return false;
}

async function drained(limitMs: number): Promise<boolean> {
  const started_ = Date.now();
  while (Date.now() - started_ < limitMs) {
    if ((await Feralin.getStatus()).queued === 0) {
      return true;
    }
    await wait(300);
  }
  return false;
}

// Yerel flush süren istekle çakışırsa boş döner; kabul görene kadar kısa aralıkla denenir.
async function flushUntilAccepted(limitMs: number) {
  const started = Date.now();
  let last = await Feralin.flush();
  while (last.status !== 202 && Date.now() - started < limitMs) {
    await wait(700);
    last = await Feralin.flush();
  }
  return last;
}

// Ağ değişimi yapılandırma değişikliği sayılır, etkinlik yeniden kurulur ve kök bileşen yeniden bağlanır: senaryo bir kez koşar.
let started = false;

async function scenario() {
  // Soğuk açılışta emülatör ağı henüz hazır olmayabilir; çevrimdışı adımı bundan bağımsız sınanır.
  report('ag-hazir', {reachable: await until(true, 90000)});

  const ready = await Feralin.initialize({projectKey: PROJECT_KEY, collectUrl: COLLECT_URL, flushIntervalMs: 600000});
  report('initialize', {ready});

  const denied = await Feralin.track('rn_before_consent', {source: 'e2e'});
  const before = await Feralin.getStatus();
  report('izin-yok', {event_id: denied, queued: before.queued, consent: before.consent, sdk: before.sdk});

  Feralin.setConsent({analytics: true, advertising: false});
  // İzinle üretilen app_first_open çekirdek tarafından hemen gönderilir ve kuyruğun kalanı peşinden gider; o sırada açık flush
  // boş döner. Bu yüzden kanıt flush sonucu değil, kuyruğun boşalması ve olayın outbox'taki satırıdır.
  const noAd = await Feralin.track('rn_no_ad', {order_id: 'rn_1', fr_click: 'clk_rn_denied', amount: 3});
  await Feralin.flush();
  const noAdDrained = await drained(20000);
  report('reklam-izni-yok', {event_id: noAd, drained: noAdDrained});

  Feralin.setConsent({analytics: true, advertising: true});
  const withAd = await Feralin.track('rn_with_ad', {order_id: 'rn_2', fr_click: 'clk_rn_1'});
  const withAdFlush = await flushUntilAccepted(15000);
  report('reklam-izni-var', {event_id: withAd, status: withAdFlush.status, batch_id: withAdFlush.batchId});

  Feralin.optOut();
  const optedOut = await Feralin.track('rn_after_opt_out');
  const afterOptOut = await Feralin.getStatus();
  report('opt-out', {event_id: optedOut, queued: afterOptOut.queued});
  Feralin.setConsent({analytics: true});

  report('wait-offline', {});
  const wentOffline = await until(false, 60000);
  const offlineEvent = await Feralin.track('rn_offline', {order_id: 'rn_3'});
  const offlineFlush = await Feralin.flush();
  await wait(1000);
  const queued = await Feralin.getStatus();
  report('cevrimdisi', {network_off: wentOffline, event_id: offlineEvent, status: offlineFlush.status, queued: queued.queued});

  report('wait-online', {});
  const backOnline = await until(true, 60000);
  // Ağ dinleyicisi kuyruğu kendiliğinden gönderebilir, açık flush o sırada boş döner; kanıt boşalan kuyruk ve outbox satırıdır.
  await Feralin.flush();
  const onlineDrained = await drained(30000);
  const after = await Feralin.getStatus();
  report('cevrimici', {network_on: backOnline, event_id: offlineEvent, drained: onlineDrained, queued: after.queued});
  report('done', {});
}

export default function App() {
  const [text, setText] = useState('Feralin RN E2E');
  useEffect(() => {
    if (started) {
      return;
    }
    started = true;
    scenario()
      .then(() => setText('bitti'))
      .catch(error => {
        report('error', {name: error?.name ?? 'unknown'});
        setText('hata');
      });
  }, []);
  return (
    <SafeAreaView>
      <Text>{text}</Text>
    </SafeAreaView>
  );
}
