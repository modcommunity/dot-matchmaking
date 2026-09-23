class_name DotMmAllocatorList
extends RefCounted

## Places matches on a fixed list of servers, one match per server at a time.
##
## The allocator a small deployment actually has: a handful of servers it already runs,
## per region, and no orchestrator. A fleet that starts servers on demand writes its own
## allocator with the same one method and hands it to [member DotMatchmaker.allocator].
##
## [b]A match that cannot be placed is not lost.[/b] [method allocate] fails, the matchmaker
## puts every ticket back at its original place, and the next pass tries again — so a
## region whose servers are all busy delays matches rather than dropping them.

## Each: [code]{id, address, region, playlists: Array of ids (empty = any)}[/code].
var servers: Array = []

## server id -> match id
var _busy: Dictionary = {}


func add_server(id: String, address: String, region: String, playlist_ids: Array = []) -> void:
	servers.append({"id": id, "address": address, "region": region, "playlists": playlist_ids})


func allocate(m: DotMmMatch) -> DotResult:
	for s_v in servers:
		var s: Dictionary = s_v
		var sid := str(s.get("id", ""))
		if _busy.has(sid):
			continue
		if str(s.get("region", "")) != m.region:
			continue
		var allowed: Array = s.get("playlists", [])
		if not allowed.is_empty() and not allowed.has(String(m.playlist)) and not allowed.has(m.playlist):
			continue
		_busy[sid] = m.id
		return DotResult.success({"server": sid, "address": str(s.get("address", "")), "match": m.id})
	return DotResult.fail(
		DotError.CODE_STATE,
		"No server is free in %s." % m.region,
		String(m.playlist)
	)


## Frees the server a match was on. Call when the game on it ends.
func release(match_id: String) -> bool:
	for sid in _busy.keys():
		if str(_busy[sid]) == match_id:
			_busy.erase(sid)
			return true
	return false


func free_count(region: String = "") -> int:
	var n := 0
	for s_v in servers:
		var s: Dictionary = s_v
		if _busy.has(str(s.get("id", ""))):
			continue
		if region != "" and str(s.get("region", "")) != region:
			continue
		n += 1
	return n
