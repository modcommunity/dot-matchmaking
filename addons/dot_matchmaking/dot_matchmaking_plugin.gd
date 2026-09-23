@tool
extends EditorPlugin

## Editor entry point for dot-matchmaking. Registers inspector types only.
##
## No autoloads: a lobby server and a suite both run two matchmakers in one process, and a
## global would make them one.

const _ICON := "res://addons/dot_matchmaking/icon_placeholder.svg"

const _TYPES := [
	[
		"DotMatchmaker",
		"Node",
		"res://addons/dot_matchmaking/runtime/dot_matchmaker.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
