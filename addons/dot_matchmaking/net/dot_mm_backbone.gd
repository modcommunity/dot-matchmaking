class_name DotMmBackbone
extends RefCounted

## The TMC backbone as the authority on ratings: results go up, ratings come back.
##
## [b]Written ahead of its endpoints.[/b] website-city has parties, statistics and
## leaderboards and has no skill rating of any kind yet; the contract this speaks is in
## [code]docs/backbone-contract.md[/code] in this repository, shaped like the stats
## routes dot-stats already uses so that the site half is a copy of a pattern it already
## has rather than a new one. Until the routes exist every call fails with the backbone's
## own 404 and the local store keeps working, which is the state a self-hosted ranked
## server is in permanently.
##
## [b]The site rates, the game does not.[/b] A game server that computed ratings and filed
## the numbers could file any numbers, and ratings are the one figure here that decides
## who other people are made to play against. So [method submit] sends the RESULT — sides,
## places, participation, leavers — and stores whatever the site answers. The algorithm is
## deliberately duplicated in the site (the dot-stats precedent: a rule that lives only in
## the game is one the site cannot check), and both halves test it against the same
## worked example from the Glicko-2 paper.
##
## [b]dot-auth is not a dependency and its client is not named.[/b] [member client] is any
## object with [code]post_integration(path, body)[/code] and
## [code]get_integration(path, query)[/code], which is [code]DotBackboneClient[/code]: it
## stamps [code]ts[/code] and [code]nonce[/code] and holds the credential, so nothing here
## knows a token exists.
##
## [b]A player id is a pseudonym, never an account id.[/b] The same refusal dot-stats makes,
## for the same reason: an id shaped like [code]backbone:…[/code] is refused before it
## leaves the server.

const CHANNEL := "matchmaking.backbone"

const DEFINE_PATH := "rating/define"
const SUBMIT_PATH := "rating/submit"
const PLAYERS_PATH := "rating/players"

const SCOPE_READ := "RATING_READ"
const SCOPE_WRITE := "RATING_WRITE"

const ACCOUNT_PREFIX := "backbone:"

## Results kept for retry when the backbone is unreachable. Past this the oldest goes.
const MAX_PENDING := 200

## The site's own bounds (website-city `src/types/integration/rating.ts`): queues one
## [code]define[/code] may declare, and players one [code]players[/code] read may name. Past
## either the site refuses the WHOLE request with a 400, which is not retryable -- so
## every queue, or every rating, went missing because there was one too many.
const DEFINE_BATCH := 25
const READ_BATCH := 100

var client: Object = null

## Where answers land. Usually the matchmaker's own store.
var store: DotMmRatingStore = null

var _pending: Array = []
var sent: int = 0
var dropped: int = 0
var failures: int = 0


func _init(p_client: Object = null, p_store: DotMmRatingStore = null) -> void:
	client = p_client
	store = p_store


## Tells the site which queues exist and their shape, [constant DEFINE_BATCH] at a time.
## Value: the last batch's answer.
func define(playlists: Array) -> DotResult:
	var rows := []
	for pl_v in playlists:
		var pl: DotMmPlaylist = pl_v
		rows.append({
			"id": String(pl.id),
			# The site requires a name; a playlist's display name defaults to empty, and one
			# nameless queue used to have the whole declaration refused.
			"name": pl.display_name if pl.display_name.strip_edges() != "" else String(pl.id),
			"game": pl.game,
			"teams": pl.teams,
			"teamSize": pl.team_size,
			"ranked": pl.ranked,
			"placementGames": pl.placement_games,
		})
	var res := DotResult.success({"ok": true, "created": 0, "updated": 0})
	for i in range(0, rows.size(), DEFINE_BATCH):
		res = await _post(DEFINE_PATH, {"playlists": rows.slice(i, i + DEFINE_BATCH)})
		if not res.ok:
			return res
	return res


## Files one finished match. See [method DotMatchmaker.report_result] for the arguments.
func submit(playlist_id: StringName, match_id: String, sides: Array, placements: Array,
		participation: Dictionary = {}, leavers: PackedStringArray = PackedStringArray()) -> DotResult:
	var body_sides := []
	for side in sides:
		var rows := []
		for pid_v in side:
			var pid := str(pid_v)
			if pid.begins_with(ACCOUNT_PREFIX):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"an account id is not a player key",
					"use the scoped key; see dot-stats' reporter for why"
				)
			rows.append({
				"player": pid,
				"participation": clampf(float(participation.get(pid, 1.0)), 0.0, 1.0),
				"leaver": leavers.has(pid),
			})
		body_sides.append(rows)

	var body := {
		"playlist": String(playlist_id),
		"matchId": match_id,
		"sides": body_sides,
		"placements": placements,
	}
	var res := await _post(SUBMIT_PATH, body)
	if not res.ok:
		if res.is_retryable():
			_pending.append(body)
			while _pending.size() > MAX_PENDING:
				_pending.pop_front()
				dropped += 1
		return res
	return _absorb(playlist_id, res.value)


## Retries results that failed to send, oldest first, stopping at the first failure.
func flush() -> DotResult:
	var done := 0
	while not _pending.is_empty():
		var body: Dictionary = _pending[0]
		var res := await _post(SUBMIT_PATH, body)
		if not res.ok:
			return res if done == 0 else DotResult.success(done)
		_pending.pop_front()
		_absorb(StringName(str(body.get("playlist", ""))), res.value)
		done += 1
	return DotResult.success(done)


## Pulls current ratings for [param player_ids] into [member store], [constant READ_BATCH]
## at a time. Value: how many ratings were stored.
func refresh(playlist_id: StringName, player_ids: PackedStringArray) -> DotResult:
	if client == null or not client.has_method("get_integration"):
		return DotResult.fail(DotError.CODE_STATE, "no backbone client")
	var stored := 0
	for i in range(0, player_ids.size(), READ_BATCH):
		var res: DotResult = await client.call("get_integration", PLAYERS_PATH, {
			"playlist": String(playlist_id),
			"players": ",".join(player_ids.slice(i, i + READ_BATCH)),
		})
		if not res.ok:
			return _explain(res, SCOPE_READ)
		var got := _absorb(playlist_id, res.value)
		if not got.ok:
			return got
		stored += int(got.value)
	return DotResult.success(stored)


func pending_count() -> int:
	return _pending.size()


## Stores the ratings a response carries: [code]{ok, ratings: {player: {...}}}[/code].
func _absorb(playlist_id: StringName, value: Variant) -> DotResult:
	if not (value is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "the backbone answered with something that is not an object")
	var ratings: Variant = (value as Dictionary).get("ratings", {})
	if not (ratings is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "ratings is not an object")
	var n := 0
	for pid in ratings:
		var raw: Variant = (ratings as Dictionary)[pid]
		if not (raw is Dictionary):
			continue
		var parsed := DotMmRating.from_dict(raw as Dictionary)
		if not parsed.ok:
			DotLog.warn(CHANNEL, "a rating from the backbone was refused", {"player": str(pid), "detail": str(parsed.error)})
			continue
		if store != null:
			store.put(str(pid), playlist_id, parsed.value)
		n += 1
	return DotResult.success(n)


func _post(path: String, body: Dictionary) -> DotResult:
	if client == null or not client.has_method("post_integration"):
		return DotResult.fail(DotError.CODE_STATE, "no backbone client")
	var res: DotResult = await client.call("post_integration", path, body)
	if res.ok:
		sent += 1
		return res
	failures += 1
	return _explain(res, SCOPE_WRITE)


func _explain(res: DotResult, scope: String) -> DotResult:
	if res.error != null and res.error.http_status == 403:
		return res.wrap("the integration credential needs the %s scope" % scope)
	if res.error != null and res.error.http_status == 404:
		return res.wrap("the backbone has no rating routes yet; see docs/backbone-contract.md")
	return res
