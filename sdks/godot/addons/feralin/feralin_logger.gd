extends Logger

## Godot 4.5+ Logger kancası: motor ve GDScript hatalarını Feralin.enable_log_error_capture() ile fr_error olarak iletir.
## Logger sınıfı eski sürümlerde yoktur; bu yüzden dosya yalnız çalışma zamanında, sınıf varsa yüklenir. HİÇ ÇALIŞTIRILMADI (Godot yok).
## _log_error herhangi bir iş parçacığından çağrılabilir: işlem ana iş parçacığına call_deferred ile taşınır.

var _owner: Object


func _init(owner: Object = null) -> void:
	_owner = owner


# error_type: 0 hata, 1 uyarı, 2 betik, 3 gölgelendirici. Uyarılar gönderilmez.
func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
	if error_type == 1 or _owner == null or not is_instance_valid(_owner):
		return
	var message := rationale if not rationale.is_empty() else code
	# Hata türü olarak dosya yolu ya da işlev adı değil, yalnız hata sınıfı kullanılır; ayrıntı iletiden temizlenerek gider.
	_owner.call_deferred("_on_log_error", "GodotError" if error_type == 0 else "ScriptError", message, false)
