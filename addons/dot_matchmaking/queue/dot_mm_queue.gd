class_name DotMmQueue
extends RefCounted

## One playlist's queue, and the pure function that turns waiting tickets into matches.
##
## [b]Oldest first, always.[/b] Each pass walks the tickets in the order they arrived and
## tries to build a match around each one — the anchor — from whoever is compatible with
## it. The anchor is the one whose window has grown the most, so the question asked is
## always "who can the person who has waited longest play with", which is the only
## ordering that cannot starve anybody: whoever is stuck at the edge of the ladder
## eventually becomes the oldest, and the window grows until it reaches somebody.
##
## [b]Where, before who.[/b] A match is placed in one region, and a ticket is only a
## candidate for a region it can reach within [i]its own[/i] latency ceiling — never the
## anchor's. A long wait is a reason for the person who waited to accept a worse match,
## not for a newcomer to be handed eighty extra milliseconds on their first search.
##
## [b]Filling is a search, bounded.[/b] Candidates are tried closest in skill first, and a
## set that fills the match but cannot be split into even sides (three parties of two for
## two sides of three) or is too lopsided for the anchor's current quality bar is
## abandoned for the next set rather than accepted. The search has a node budget, because
## a queue pass runs inside a frame and must finish in one whatever is waiting.
##
## [b]No clock inside.[/b] [method form] takes [code]now[/code]. Everything here is a function
## of the tickets and that number, which is what lets the suite replay a queue minute by
## minute in a millisecond.

const CHANNEL := "matchmaking.queue"

## Subsets tried per anchor before giving up on it for this pass.
const SEARCH_BUDGET := 4000

var playlist: DotMmPlaylist = null

## ticket id -> DotMmTicket
var _tickets: Dictionary = {}

## player id -> ticket id, so nobody is in one queue twice.
var _players: Dictionary = {}

var _formed: int = 0


func _init(p_playlist: DotMmPlaylist = null) -> void:
	playlist = p_playlist


func add(ticket: DotMmTicket) -> DotResult:
	var ok := ticket.validate(playlist)
	if not ok.ok:
		return ok
	if _tickets.has(ticket.id):
		return DotResult.fail(DotError.CODE_CONFLICT, "That ticket is already queued.", ticket.id)
	for pid in ticket.member_ids():
		if _players.has(pid):
			return DotResult.fail(
				DotError.CODE_CONFLICT,
				"Somebody on this ticket is already in the queue.",
				"%s is on %s" % [pid, _players[pid]]
			)
	ticket.playlist = playlist.id
	_tickets[ticket.id] = ticket
	for pid in ticket.member_ids():
		_players[pid] = ticket.id
	return DotResult.success(ticket)


func remove(ticket_id: String) -> DotMmTicket:
	var t: DotMmTicket = _tickets.get(ticket_id)
	if t == null:
		return null
	_tickets.erase(ticket_id)
	for pid in t.member_ids():
		if str(_players.get(pid, "")) == ticket_id:
			_players.erase(pid)
	return t


func get_ticket(ticket_id: String) -> DotMmTicket:
	return _tickets.get(ticket_id)


func ticket_of_player(player_id: String) -> String:
	return str(_players.get(player_id, ""))


func size() -> int:
	return _tickets.size()


func players() -> int:
	return _players.size()


## Every ticket, oldest first. Ties by id so the order is total.
func ordered() -> Array:
	var out := _tickets.values()
	out.sort_custom(func(a: DotMmTicket, b: DotMmTicket) -> bool:
		if a.enqueued_at != b.enqueued_at:
			return a.enqueued_at < b.enqueued_at
		return a.id < b.id
	)
	return out


## One pass: every match that can be made now. Matched tickets leave the queue.
func form(now: float) -> Array:
	var out := []
	var consumed := {}
	var order := ordered()

	for anchor_v in order:
		var anchor: DotMmTicket = anchor_v
		if consumed.has(anchor.id):
			continue
		var m := _build_around(anchor, order, consumed, now)
		if m == null:
			continue
		for t in m.tickets():
			consumed[(t as DotMmTicket).id] = true
		out.append(m)

	for m in out:
		for t in (m as DotMmMatch).tickets():
			remove((t as DotMmTicket).id)
	_formed += out.size()
	return out


## How long the oldest ticket has waited, for a queue screen's "estimated wait".
func oldest_wait(now: float) -> float:
	var order := ordered()
	if order.is_empty():
		return 0.0
	return (order[0] as DotMmTicket).waited(now)


func _build_around(anchor: DotMmTicket, order: Array, consumed: Dictionary, now: float) -> DotMmMatch:
	var pl := playlist
	var waited := anchor.waited(now)
	var window := pl.window_after(waited)
	var quality_floor := pl.quality_after(waited)
	var anchor_r := anchor.matching_rating(pl.party_skill_blend, pl.premade_bonus)
	var need := pl.players_per_match()

	for region in _regions_for(anchor, now):
		var pool := []
		for t_v in order:
			var t: DotMmTicket = t_v
			if t == anchor or consumed.has(t.id):
				continue
			if not t.latencies.has(region):
				continue
			if float(t.latencies[region]) > pl.latency_after(t.waited(now)):
				continue
			var r := t.matching_rating(pl.party_skill_blend, pl.premade_bonus)
			if absf(r - anchor_r) > window:
				continue
			pool.append(t)

		pool.sort_custom(func(a: DotMmTicket, b: DotMmTicket) -> bool:
			var da := absf(a.matching_rating(pl.party_skill_blend, pl.premade_bonus) - anchor_r)
			var db := absf(b.matching_rating(pl.party_skill_blend, pl.premade_bonus) - anchor_r)
			if da != db:
				return da < db
			if a.enqueued_at != b.enqueued_at:
				return a.enqueued_at < b.enqueued_at
			return a.id < b.id
		)

		var budget: Array[int] = [SEARCH_BUDGET]
		var chosen: Array = [anchor]
		var found := _search(pool, 0, chosen, anchor.size(), need, quality_floor, budget)
		if found == null:
			continue

		found.region = region
		found.window = window
		found.formed_at = now
		for t in found.tickets():
			found.longest_wait = maxf(found.longest_wait, (t as DotMmTicket).waited(now))
		found.id = DotHash.sha256_text(",".join(found.ticket_ids()) + "@" + str(now)).substr(0, 16)
		found.playlist = pl.id
		return found

	return null


## Regions the anchor can play in now, nearest first.
func _regions_for(anchor: DotMmTicket, now: float) -> Array:
	var cap := playlist.latency_after(anchor.waited(now))
	var out := []
	for region in anchor.latencies:
		if float(anchor.latencies[region]) <= cap:
			out.append(str(region))
	out.sort_custom(func(a: String, b: String) -> bool:
		var la := float(anchor.latencies[a])
		var lb := float(anchor.latencies[b])
		if la != lb:
			return la < lb
		return a < b
	)
	return out


## Depth-first over the pool, closest first, for a full set that splits and is fair enough.
func _search(pool: Array, from: int, chosen: Array, count: int, need: int,
		quality_floor: float, budget: Array[int]) -> DotMmMatch:
	if count == need:
		return _try(chosen, quality_floor)
	for i in range(from, pool.size()):
		budget[0] -= 1
		if budget[0] <= 0:
			return null
		var t: DotMmTicket = pool[i]
		if count + t.size() > need:
			continue
		chosen.append(t)
		var got := _search(pool, i + 1, chosen, count + t.size(), need, quality_floor, budget)
		if got != null:
			return got
		chosen.pop_back()
	return null


func _try(chosen: Array, quality_floor: float) -> DotMmMatch:
	var pl := playlist
	var sizes := []
	var strengths := []
	for t_v in chosen:
		var t: DotMmTicket = t_v
		sizes.append(t.size())
		strengths.append(t.matching_rating(pl.party_skill_blend, pl.premade_bonus) * t.size())

	var split := DotMmBalance.split(sizes, strengths, pl.teams, pl.team_size)
	if split.is_empty():
		return null

	var m := DotMmMatch.new()
	for side in split:
		var tickets := []
		for i in side:
			tickets.append(chosen[int(i)])
		m.sides.append(tickets)

	var odds := evaluate(m.sides, pl)
	m.win_chance = odds[0]
	m.quality = odds[1]
	if m.quality < quality_floor:
		return null
	return m


## [code][win chance of side 0, quality][/code] for a proposed set of sides.
##
## Quality compares the strongest side with the weakest, so it means the same thing for
## two sides and for eight: how close the most lopsided pairing in the match is to even.
static func evaluate(sides: Array, pl: DotMmPlaylist) -> Array:
	var means: Array[float] = []
	var devs: Array[float] = []
	for side in sides:
		var total := 0.0
		var count := 0
		var dev_sq := 0.0
		for t_v in side:
			var t: DotMmTicket = t_v
			total += t.matching_rating(pl.party_skill_blend, pl.premade_bonus) * t.size()
			count += t.size()
			dev_sq += t.deviation() * t.deviation() * t.size()
		means.append(total / maxi(1, count))
		devs.append(sqrt(dev_sq / maxi(1, count)))

	var hi := 0
	var lo := 0
	for i in range(means.size()):
		if means[i] > means[hi]:
			hi = i
		if means[i] < means[lo]:
			lo = i

	var p_extreme := DotMmGlicko2.expected(means[hi], devs[hi], means[lo], devs[lo])
	var quality := 1.0 - 2.0 * absf(p_extreme - 0.5)
	var p0 := -1.0
	if means.size() == 2:
		p0 = DotMmGlicko2.expected(means[0], devs[0], means[1], devs[1])
	return [p0, quality]


func describe_lines(now: float) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("%s: %d tickets, %d players, oldest %.0fs, %d formed" % [
		playlist.id, size(), players(), oldest_wait(now), _formed,
	])
	return out
