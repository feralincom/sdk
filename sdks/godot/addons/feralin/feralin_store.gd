extends RefCounted

## Kalıcı şifreli olay kuyruğu ve küçük işaret deposu. events.log her satırda "kimlik TAB enc1:..." (feralin_crypto.gd), markers.log her
## satırda "anahtar TAB değer". Ekleme dosya sonuna yazar; silme geçici dosya üzerinden yeniden yazar. Yarım kalmış son satır sonraki
## eklemede tamamlanır; geçersiz ya da açılamayan satır atılır. G/Ç hatası oyuna yansımaz: failures artar.
## Bu dosya hiç çalıştırılmadı (Godot yok).

const FeralinCrypto := preload("res://addons/feralin/feralin_crypto.gd")

var directory := ""
var failures := 0
## Test ve platform köprüsü için: 12 baytlık IV kaynağı.
var random_bytes: Callable = func(count: int) -> PackedByteArray: return Crypto.new().generate_random_bytes(count)

var _key := PackedByteArray()
var _tail_checked := false


func _init(dir: String = "", key: PackedByteArray = PackedByteArray()) -> void:
	directory = dir
	_key = key
	if not directory.is_empty():
		var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if error != OK and error != ERR_ALREADY_EXISTS:
			failures += 1


## Veri anahtarını alır ya da üretir. protector: {"name": String, "protect": Callable, "unprotect": Callable}; Callable PackedByteArray
## alıp PackedByteArray döndürür, başarısızlıkta boş dizi. Dönüş: {"key": PackedByteArray, "protection": String}; anahtar alınamazsa
## key boş olur ve çağıran kuyruğu bellekte tutar (düz metne düşmez).
static func open_key(dir: String, protector: Dictionary = {}, rng: Callable = Callable()) -> Dictionary:
	var name: String = protector.get("name", "local_file")
	var protect: Callable = protector.get("protect", func(data: PackedByteArray) -> PackedByteArray: return data)
	var unprotect: Callable = protector.get("unprotect", func(data: PackedByteArray) -> PackedByteArray: return data)
	var path := dir.path_join("queue.key")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var wrapped := file.get_buffer(file.get_length())
			file.close()
			var existing: PackedByteArray = unprotect.call(wrapped)
			if existing.size() == 32:
				return {"key": existing, "protection": name}
		# Sarmalayıcı anahtarı açamıyor (cihaz değişti, Keystore sıfırlandı): eski satırlar zaten okunamaz, yeni anahtar üretilir.
	var fresh: PackedByteArray = rng.call(32) if rng.is_valid() else Crypto.new().generate_random_bytes(32)
	if fresh.size() != 32:
		return {"key": PackedByteArray(), "protection": "none"}
	var sealed: PackedByteArray = protect.call(fresh)
	if sealed.is_empty():
		return {"key": PackedByteArray(), "protection": "none"}
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		return {"key": PackedByteArray(), "protection": "none"}
	out.store_buffer(sealed)
	out.close()
	return {"key": fresh, "protection": name}


## Anahtarı siler; eski şifreli satırlar bir daha açılmaz.
static func delete_key(dir: String) -> void:
	var path := dir.path_join("queue.key")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _events_path() -> String:
	return directory.path_join("events.log")


func _markers_path() -> String:
	return directory.path_join("markers.log")


## Eskiden yeniye: [{"id": String, "payload": String}]. Açılamayan satırlar diskten de silinir.
func load_events() -> Array:
	var result: Array = []
	var seen := {}
	var broken: Array = []
	for line in _read_lines(_events_path()):
		if line.length() <= 27 or line[26] != "\t":
			continue
		var id: String = line.substr(0, 26)
		if seen.has(id):
			continue
		seen[id] = true
		var opened := FeralinCrypto.decrypt_line(_key, line.substr(27), id)
		if opened["ok"]:
			result.append({"id": id, "payload": opened["text"]})
		else:
			broken.append(id)
	if not broken.is_empty():
		remove(broken)
	return result


func add(id: String, payload: String) -> void:
	if id.length() != 26 or payload.contains("\n") or payload.contains("\r") or _key.size() != 32:
		return
	_ensure_tail()
	var path := _events_path()
	var file := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		failures += 1
		return
	file.seek_end()
	var iv: PackedByteArray = random_bytes.call(FeralinCrypto.IV_BYTES)
	file.store_string(id + "\t" + FeralinCrypto.encrypt_line(_key, iv, payload, id) + "\n")
	file.close()


func remove(ids: Array) -> void:
	if ids.is_empty():
		return
	var drop := {}
	for id in ids:
		drop[String(id)] = true
	var keep: Array = []
	for line in _read_lines(_events_path()):
		if line.length() > 26 and line[26] == "\t" and not drop.has(line.substr(0, 26)):
			keep.append(line)
	_rewrite(_events_path(), keep)
	_tail_checked = true


func clear() -> void:
	if FileAccess.file_exists(_events_path()):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_events_path()))
	_tail_checked = true


## Dönüş: {"found": bool, "value": String}.
func get_marker(key: String) -> Dictionary:
	var markers := _read_markers()
	return {"found": markers.has(key), "value": markers.get(key, "")}


func put_marker(key: String, value: String) -> void:
	if key.is_empty() or key.contains("\t") or key.contains("\n") or key.contains("\r") or value.contains("\n") or value.contains("\r"):
		return
	var markers := _read_markers()
	markers[key] = value
	_write_markers(markers)


func remove_marker(key: String) -> void:
	var markers := _read_markers()
	if markers.erase(key):
		_write_markers(markers)


func _read_markers() -> Dictionary:
	var markers := {}
	for line in _read_lines(_markers_path()):
		var tab: int = line.find("\t")
		if tab > 0:
			markers[line.substr(0, tab)] = line.substr(tab + 1)
	return markers


func _write_markers(markers: Dictionary) -> void:
	var lines: Array = []
	for key in markers:
		lines.append(String(key) + "\t" + String(markers[key]))
	_rewrite(_markers_path(), lines)


func _read_lines(path: String) -> Array:
	var lines: Array = []
	if not FileAccess.file_exists(path):
		return lines
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures += 1
		return lines
	var text := file.get_as_text()
	file.close()
	for line in text.split("\n"):
		var trimmed := String(line).rstrip("\r")
		if not trimmed.is_empty():
			lines.append(trimmed)
	return lines


func _rewrite(path: String, lines: Array) -> void:
	if lines.is_empty():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		failures += 1
		return
	file.store_string("\n".join(PackedStringArray(lines)) + "\n")
	file.close()
	# rename hedef varsa bazı platformlarda başarısız olur: önce siler.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path)) != OK:
		failures += 1


## Son bayt satır sonu değilse (yarım yazma) tamamlanır; sonraki geçerli olay bozuk satıra yapışmaz.
func _ensure_tail() -> void:
	if _tail_checked:
		return
	_tail_checked = true
	var path := _events_path()
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		return
	var length := file.get_length()
	if length > 0:
		file.seek(length - 1)
		if file.get_8() != 0x0A:
			file.seek_end()
			file.store_8(0x0A)
	file.close()
