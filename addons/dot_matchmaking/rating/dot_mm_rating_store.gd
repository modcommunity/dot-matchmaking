class_name DotMmRatingStore
extends RefCounted

## Where ratings live between matches. This base keeps them in memory; subclass to persist.
##
## [b]Keyed by (player, playlist), and a missing entry is a newcomer, not an error.[/b]
## Somebody's first search in a queue must work, and "no rating" is precisely the state
## Glicko-2 was designed to describe: 1500, with a deviation wide enough to say we know
## nothing. Returning an error there instead would make every game write the same
## fallback, and one of them would write 0.
##
## [b]Synchronous on purpose.[/b] The matcher asks for a rating for every member of every
## ticket it is handed, inside a queue pass, and an await in the middle of that is a pass
## that can be interleaved with the next one. A store that has to go over a network keeps
## a local copy it refreshes on its own schedule — [DotMmBackbone] does exactly that — and
## answers from it here.

var _ratings: Dictionary = {}


## The rating, or a newcomer's if there is none. Never null, and always a copy.
func fetch(player_id: String, playlist: StringName) -> DotMmRating:
	var r: DotMmRating = _ratings.get(_key(player_id, playlist))
	if r == null:
		return DotMmRating.new()
	return r.copy()


func has_rating(player_id: String, playlist: StringName) -> bool:
	return _ratings.has(_key(player_id, playlist))


func put(player_id: String, playlist: StringName, rating: DotMmRating) -> DotResult:
	if player_id == "":
		return DotResult.fail(DotError.CODE_INVALID, "a rating for nobody")
	_ratings[_key(player_id, playlist)] = rating.copy()
	return DotResult.success(null)


func count() -> int:
	return _ratings.size()


## Every entry as plain data, for a file or a wire.
func to_dict() -> Dictionary:
	var out := {}
	for k in _ratings:
		out[k] = (_ratings[k] as DotMmRating).to_dict()
	return out


## Replaces the contents with what [method to_dict] wrote. Refuses the whole load on one
## bad entry, because a store that half-loaded is a store in which some people are
## newcomers again and nothing says which.
func load_dict(d: Dictionary) -> DotResult:
	var next := {}
	for k in d:
		var key := str(k)
		if not key.contains("|"):
			return DotResult.fail(DotError.CODE_PARSE, "a rating key without a playlist", key)
		var raw: Variant = d[k]
		if not (raw is Dictionary):
			return DotResult.fail(DotError.CODE_PARSE, "a rating entry that is not an object", key)
		var parsed := DotMmRating.from_dict(raw as Dictionary)
		if not parsed.ok:
			return parsed.wrap("rating '%s'" % key)
		next[key] = parsed.value
	_ratings = next
	return DotResult.success(next.size())


static func _key(player_id: String, playlist: StringName) -> String:
	# The playlist goes first so one queue's entries sort together in a file.
	return "%s|%s" % [playlist, player_id]
