@tool
extends EditorPlugin

## Eklenti etkinleşince "Feralin" autoload'unu ve proje ayarlarını kaydeder.

const AUTOLOAD_NAME := "Feralin"
const AUTOLOAD_PATH := "res://addons/feralin/feralin.gd"
const SETTINGS := {
	"feralin/project_key": "",
	"feralin/collect_url": "",
}


func _enable_plugin() -> void:
	for key in SETTINGS:
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, SETTINGS[key])
		ProjectSettings.set_initial_value(key, SETTINGS[key])
	ProjectSettings.save()
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
