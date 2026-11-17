extends SceneTree

## Gerçek toplayıcıya karşı uçtan uca tüketici. scripts/sdk-e2e/targets/godot.mjs tarafından boş bir Godot projesine kurulan
## addon ile koşar: godot --headless --path <proje> -s res://e2e_consumer.gd
## Ortam: FERALIN_E2E_COLLECT_URL, FERALIN_E2E_PROJECT_KEY, FERALIN_E2E_CHECKS (outbox_check.go satırları),
## FERALIN_E2E_EVENT_CHECKS (unity_event_check.go satırları: olay adı ve özellik), FERALIN_E2E_QUEUE_DIR (kalıcı kuyruk dizini).
## Godot derleme hatasında da 0 ile çıkabildiğinden başarı yalnız son satırdaki "E2E_GODOT_OK" ile kabul edilir.

const FeralinNode := preload("res://addons/feralin/feralin.gd")

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _fail(message: String) -> void:
	_failures += 1
	printerr("KALDI: " + message)


func _env(name: String) -> String:
	var value := OS.get_environment(name)
	if value.is_empty():
		_fail(name + " tanımsız")
	return value


func _append(path: String, lines: Array) -> void:
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		_fail("denetim dosyası açılamadı: " + path)
		return
	file.seek_end()
	for line in lines:
		file.store_string(str(line) + "\n")
	file.close()


func _make_client(collect_url: String, key: String, queue_dir: String) -> Node:
	var client: Node = FeralinNode.new()
	root.add_child(client)
	# Otomatik zamanlayıcı kapalı: gönderim yalnız açık flush ile olur, sonuç sırası belirli kalır.
	if not client.configure(key, collect_url, {"queue_directory": queue_dir, "start_attribution": false, "flush_interval_sec": 0.0, "timeout_sec": 10.0}):
		_fail("configure reddetti: " + client.core.config_error)
	return client


func _flush(client: Node) -> Dictionary:
	client.flush()
	var result: Dictionary = await client.flushed
	return result


func _run() -> void:
	var collect_url := _env("FERALIN_E2E_COLLECT_URL")
	var key := _env("FERALIN_E2E_PROJECT_KEY")
	var checks := _env("FERALIN_E2E_CHECKS")
	var event_checks := _env("FERALIN_E2E_EVENT_CHECKS")
	var queue_dir := _env("FERALIN_E2E_QUEUE_DIR")
	if _failures > 0:
		quit(1)
		return
	var run_id := str(Time.get_unix_time_from_system()).replace(".", "")

	# 1) İzin yokken olay üretilmez.
	var client := _make_client(collect_url, key, queue_dir)
	if not client.track_level_start("dunya_0").is_empty():
		_fail("izinsiz olay üretildi")
	client.set_consent({"analytics": true})

	# 2) Oyun olayları, satın alma beyanı ve reklam geliri gerçek toplayıcıya gider.
	var level_start: Dictionary = client.track_level_start("dunya_1", 1)
	var level_complete: Dictionary = client.track_level_complete("dunya_1", 1, 1200, 33500)
	var level_fail: Dictionary = client.track_level_fail("dunya_2", 2, 10, 12500, "zaman_doldu")
	var source: Dictionary = client.track_economy_source("gem", 50, "quest_reward", "gift_box")
	var sink: Dictionary = client.track_economy_sink("gem", 20, "shop", "sword")
	var shown: Dictionary = client.track_rewarded_ad_shown("revive", "admob")
	var rewarded: Dictionary = client.track_rewarded_ad_complete("revive", "admob", 1, "life")
	var purchase: Dictionary = client.track_revenue({"transaction_id": "txn_godot_" + run_id, "amount_minor": 4999, "currency": "TRY", "product_id": "gold_pack", "properties": {"verified": true}})
	var ad_revenue: Dictionary = client.track_ad_revenue({"network": "admob", "ad_format": "rewarded", "revenue_micros": 12500, "currency": "USD", "precision": "estimated"})
	var tracked := [level_start, level_complete, level_fail, source, sink, shown, rewarded, purchase, ad_revenue]
	for item in tracked:
		if item.is_empty():
			_fail("olay üretilmedi")
	if _failures > 0:
		quit(1)
		return
	var sent := await _flush(client)
	print("ilk gönderim: ", sent)
	if sent["status"] != 202 or sent["accepted"] != tracked.size() or sent["retained"] != 0:
		_fail("ilk gönderim 202 ile kabul edilmeli, kuyruk boşalmalı: %s" % [sent])
	var outbox_lines: Array = []
	var event_lines: Array = []
	for item in tracked:
		outbox_lines.append("once " + item["event_id"])
		outbox_lines.append("platform godot:" + item["event_id"])
		event_lines.append("event %s:%s" % [item["event_name"], item["event_id"]])
		event_lines.append("session " + item["event_id"])
	event_lines.append("prop %s:level_id=\"dunya_1\"" % level_complete["event_id"])
	event_lines.append("prop %s:score=1200" % level_complete["event_id"])
	event_lines.append("prop %s:fail_reason=\"zaman_doldu\"" % level_fail["event_id"])
	event_lines.append("prop %s:amount=50" % source["event_id"])
	event_lines.append("prop %s:currency_name=\"gem\"" % sink["event_id"])
	event_lines.append("prop %s:placement=\"revive\"" % rewarded["event_id"])
	event_lines.append("prop %s:reward_amount=1" % rewarded["event_id"])
	event_lines.append("prop %s:amount_minor=4999" % purchase["event_id"])
	# İstemci "verified" beyan edemez: SDK çıkarır.
	event_lines.append("noprop %s:verified" % purchase["event_id"])
	event_lines.append("prop %s:revenue_micros=12500" % ad_revenue["event_id"])

	# 3) Kalıcı kuyruk ve aynı olayın tekrar gönderimi: kapalı bir adrese gönderim başarısız olur, olay şifreli kuyrukta kalır.
	# İstemci kapatılıp aynı dizinle yeniden açılınca aynı event_id ve aynı Idempotency-Key ile gerçek toplayıcıya gider.
	client.queue_free()
	await process_frame
	var offline := _make_client("http://127.0.0.1:9", key, queue_dir)
	offline.set_consent({"analytics": true})
	var persisted: Dictionary = offline.track_economy_sink("coin", 5, "retry_test")
	var failed := await _flush(offline)
	print("kapalı adrese gönderim: ", failed)
	if failed["accepted"] != 0 or failed["retained"] != 1:
		_fail("kapalı adreste olay kuyrukta kalmalı: %s" % [failed])
	offline.queue_free()
	await process_frame
	var reopened := _make_client(collect_url, key, queue_dir)
	reopened.set_consent({"analytics": true})
	var resent := await _flush(reopened)
	print("yeniden açılışta gönderim: ", resent)
	if resent["status"] != 202 or resent["accepted"] != 1 or resent["retained"] != 0:
		_fail("kalıcı kuyruktaki olay yeniden açılışta gönderilmeli: %s" % [resent])
	outbox_lines.append("once " + persisted["event_id"])
	event_lines.append("event economy_sink:" + persisted["event_id"])

	# 4) İzin geri çekilince kuyruk ve disk silinir; yeni olay üretilmez.
	reopened.set_consent({"analytics": false})
	var after_withdraw: Dictionary = reopened.track_level_start("dunya_9")
	if not after_withdraw.is_empty():
		_fail("izin geri çekildikten sonra olay üretildi")
	reopened.queue_free()

	_append(checks, outbox_lines)
	_append(event_checks, event_lines)
	if _failures > 0:
		print("E2E_GODOT_FAIL %d" % _failures)
		quit(1)
		return
	print("E2E_GODOT_OK %d olay" % (tracked.size() + 1))
	quit(0)
