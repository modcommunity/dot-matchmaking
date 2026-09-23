class_name DotMmRatingStoreFile
extends DotMmRatingStore

## Ratings in one JSON file, written atomically.
##
## For a community running its own ranked server with no backbone. Written to a temporary
## file and renamed over the old one, because a process killed half way through a write is
## the moment a rating file is most likely to be written — at the end of a match — and a
## truncated file is every player on the server starting from 1500 again.

const CHANNEL := "matchmaking.store"

var path: String = "user://matchmaking/ratings.json"


func _init(p_path: String = "") -> void:
	if p_path != "":
		path = p_path


func open() -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.success(0)
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "The ratings file is not a JSON object.", path)
	return load_dict(parsed as Dictionary)


func put(player_id: String, playlist: StringName, rating: DotMmRating) -> DotResult:
	var res := super.put(player_id, playlist, rating)
	if not res.ok:
		return res
	return save()


func save() -> DotResult:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return DotResult.failure(DotError.from_engine(made, "creating " + dir))

	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return DotResult.failure(DotError.from_engine(FileAccess.get_open_error(), tmp))
	f.store_string(JSON.stringify(to_dict(), "\t", true))
	f.close()

	var moved := DirAccess.rename_absolute(tmp, path)
	if moved != OK:
		return DotResult.failure(DotError.from_engine(moved, "replacing " + path))
	DotWeb.sync_filesystem()
	return DotResult.success(null)
