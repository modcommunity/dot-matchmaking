class_name DotMmTicket
extends RefCounted

## One entry in a queue: a person, or a party that must not be split.
##
## [b]The party is the unit, always.[/b] A matchmaker that queues members of a party
## individually and "tries" to keep them together will, under load, put two friends on
## opposite sides — which is the one outcome a party exists to prevent. So a ticket holds
## everyone who queued together and the matcher places it whole or not at all.
##
## [b]Latency is per region, measured by the client.[/b] A server cannot measure how far a
## player is from a data centre it is not in. The client pings each region's beacon and
## reports; a party's latency to a region is its [i]worst[/i] member's, because the match
## is only as playable as it is for the person furthest away.

var id: String = ""

## The playlist this ticket is waiting in.
var playlist: StringName = &""

## Everybody on it: [code]{id: String, rating: DotMmRating}[/code]. The first is who
## queued, which for a party is its leader.
var members: Array = []

## The party this came from, if any. Carried through so the result can name it.
var party_id: String = ""

## Unix seconds this ticket first entered the queue.
##
## [b]Kept across a failed accept.[/b] Nine people who accepted a match somebody else
## declined go back in with their original time, so they are next rather than last.
var enqueued_at: float = 0.0

## region id -> round-trip milliseconds, the worst of the members'.
var latencies: Dictionary = {}


static func solo(p_id: String, p_playlist: StringName, rating: DotMmRating,
		p_latencies: Dictionary, at: float) -> DotMmTicket:
	var t := DotMmTicket.new()
	t.id = p_id
	t.playlist = p_playlist
	t.members = [{"id": p_id, "rating": rating}]
	t.latencies = p_latencies.duplicate()
	t.enqueued_at = at
	return t


## A party ticket. [param member_latencies] is one region dictionary per member and is
## folded to the worst per region; a region any member did not report is dropped, since
## nothing says that person can reach it.
static func party(p_id: String, p_playlist: StringName, p_members: Array,
		member_latencies: Array, at: float, p_party_id: String = "") -> DotMmTicket:
	var t := DotMmTicket.new()
	t.id = p_id
	t.playlist = p_playlist
	t.members = p_members.duplicate()
	t.party_id = p_party_id
	t.enqueued_at = at
	t.latencies = worst_latencies(member_latencies)
	return t


static func worst_latencies(per_member: Array) -> Dictionary:
	var out := {}
	if per_member.is_empty():
		return out
	var first: Dictionary = per_member[0]
	for region in first:
		var worst := 0.0
		var everyone := true
		for m in per_member:
			var d: Dictionary = m
			if not d.has(region):
				everyone = false
				break
			worst = maxf(worst, float(d[region]))
		if everyone:
			out[region] = worst
	return out


func size() -> int:
	return members.size()


func member_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for m in members:
		out.append(str((m as Dictionary).get("id", "")))
	return out


func ratings() -> Array:
	var out := []
	for m in members:
		out.append((m as Dictionary).get("rating"))
	return out


## The rating this ticket is matched as. See [member DotMmPlaylist.party_skill_blend].
func matching_rating(blend: float, premade_bonus: float) -> float:
	if members.is_empty():
		return DotMmRating.DEFAULT_RATING
	var total := 0.0
	var best := -INF
	for r in ratings():
		var rr: DotMmRating = r
		total += rr.rating
		best = maxf(best, rr.rating)
	var mean := total / members.size()
	return lerpf(mean, best, clampf(blend, 0.0, 1.0)) + premade_bonus * (members.size() - 1)


## The largest deviation among the members, for the quality estimate.
func deviation() -> float:
	var worst := 0.0
	for r in ratings():
		worst = maxf(worst, (r as DotMmRating).deviation)
	return worst


func waited(now: float) -> float:
	return maxf(0.0, now - enqueued_at)


func validate(pl: DotMmPlaylist) -> DotResult:
	if id == "":
		return DotResult.fail(DotError.CODE_INVALID, "a ticket with no id")
	if members.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "a ticket with nobody on it", id)
	if pl != null and members.size() > pl.party_limit():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"This party is too big for %s." % pl.display_name,
			"%d members, the queue takes up to %d" % [members.size(), pl.party_limit()]
		)
	var seen := {}
	for m in members:
		var d: Dictionary = m
		var mid := str(d.get("id", ""))
		if mid == "":
			return DotResult.fail(DotError.CODE_INVALID, "a member with no id", id)
		if seen.has(mid):
			return DotResult.fail(DotError.CODE_CONFLICT, "one person twice on a ticket", mid)
		seen[mid] = true
		if not (d.get("rating") is DotMmRating):
			return DotResult.fail(DotError.CODE_INVALID, "a member with no rating", mid)
	if latencies.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"No region is reachable by everybody on this ticket.",
			id
		)
	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": id,
		"playlist": String(playlist),
		"members": Array(member_ids()),
		"party": party_id,
		"enqueued_at": enqueued_at,
		"regions": latencies.keys(),
	}
