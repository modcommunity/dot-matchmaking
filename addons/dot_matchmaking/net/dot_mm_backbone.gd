class_name DotMmBackbone
extends RefCounted

## The TMC backbone as the authority on ratings: results go up, ratings come back.
##
## [b]Written ahead of its endpoints.[/b] website-city has parties, statistics and
## leaderboards and has no skill rating of any kind yet; the contract this speaks is in
## [code]docs/backbone-contract.md[/code] in this repository, shaped like the stats
## routes dot-stats already uses so that the site half is a copy of a pattern it already
## has rather than a new one. A site without the routes answers every call with a 404 page
## (told apart from the site's own "no such playlist" 404 in [method _explain]) and the
## local store keeps working, which is the state a self-hosted ranked server is in
## permanently.
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

## The rest of the site's bounds, from the same file. A body outside any of them is refused
## whole with a 400, which is not retryable, so [method submit] and [method define] refuse
## it here first with the reason, rather than lose a match to "Invalid payload."
const MAX_SIDES := 64
const MAX_SIDE := 64
const MAX_PLAYERS := 128
const KEY_MAX := 64
const MATCH_ID_MAX := 128
const PLACEMENT_MAX := 10000
const NAME_MAX := 120
const GAME_MAX := 64
const PLACEMENT_GAMES_MAX := 1000

## What the site rates with, whatever [DotMatchmakingConfig] says (website-city
## [code]src/types/rating/glicko2.ts[/code]: [code]GLICKO_TAU[/code],
## [code]RATING_INACTIVITY_PERIOD_DAYS[/code], [code]RATING_MIN_PARTICIPATION[/code], and a
## leaver always rated as having lost). [code]define[/code] has no field for any of them, so
## a game that changes one rates by one rule offline and by another online. See
## [method parity_gaps].
const SITE_TAU := 0.5
const SITE_INACTIVITY_PERIOD_DAYS := 14.0
const SITE_MIN_PARTICIPATION := 0.25
const SITE_LEAVER_TAKES_LOSS := true

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
##
## Every queue is checked against the site's rules first, and one it would refuse fails the
## call before anything is sent. Pass the matchmaker's [param config] and a ranked queue
## whose rating rules the site will not follow is warned about (see [method parity_gaps]);
## the declaration still goes, because the site has nowhere to put the difference yet.
func define(playlists: Array, config: DotMatchmakingConfig = null) -> DotResult:
	var rows := []
	var any_ranked := false
	for pl_v in playlists:
		var pl: DotMmPlaylist = pl_v
		var problem := define_problem(pl)
		if problem != "":
			return DotResult.fail(DotError.CODE_INVALID, "the backbone would refuse this playlist: " + problem,
				String(pl.id) if pl != null else "")
		any_ranked = any_ranked or pl.ranked
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
	if config != null and any_ranked:
		var gaps := parity_gaps(config)
		if not gaps.is_empty():
			DotLog.warn(CHANNEL, "the backbone rates these queues by its own rules, not this config", {
				"differs": "; ".join(gaps),
				"see": "docs/backbone-contract.md, Rating parity",
			})
	var res := DotResult.success({"ok": true, "created": 0, "updated": 0})
	for i in range(0, rows.size(), DEFINE_BATCH):
		res = await _post(DEFINE_PATH, {"playlists": rows.slice(i, i + DEFINE_BATCH)})
		if not res.ok:
			return res
	return res


## Where [param config]'s rating rules differ from the ones the site uses, one line each;
## empty when they agree. The site has no per-playlist setting for any of these yet.
static func parity_gaps(config: DotMatchmakingConfig) -> PackedStringArray:
	var out := PackedStringArray()
	if config == null:
		return out
	if not is_equal_approx(config.tau, SITE_TAU):
		out.append("tau %.2f here, %.2f on the site" % [config.tau, SITE_TAU])
	if not is_equal_approx(config.inactivity_period_days, SITE_INACTIVITY_PERIOD_DAYS):
		out.append("a rating period is %.0f days here, %.0f on the site" % [
			config.inactivity_period_days, SITE_INACTIVITY_PERIOD_DAYS])
	if not is_equal_approx(config.min_participation, SITE_MIN_PARTICIPATION):
		out.append("participation under %.2f is unrated here, under %.2f on the site" % [
			config.min_participation, SITE_MIN_PARTICIPATION])
	if config.leaver_takes_loss != SITE_LEAVER_TAKES_LOSS:
		out.append("a leaver is rated by participation here; on the site a leaver always takes the loss")
	return out


## Why the site would refuse [param pl] in a [code]define[/code], or [code]""[/code].
static func define_problem(pl: DotMmPlaylist) -> String:
	if pl == null:
		return "a null playlist"
	var valid := pl.validate()
	if not valid.ok:
		return "%s (%s)" % [valid.error.message, String(pl.id)]
	var name := pl.display_name.strip_edges()
	if name.length() > NAME_MAX:
		return "%s: a display name is at most %d characters" % [pl.id, NAME_MAX]
	if pl.game.strip_edges().length() > GAME_MAX:
		return "%s: a game id is at most %d characters" % [pl.id, GAME_MAX]
	if pl.teams > MAX_SIDES or pl.team_size > MAX_SIDE:
		return "%s: at most %d sides of %d" % [pl.id, MAX_SIDES, MAX_SIDE]
	if pl.placement_games < 0 or pl.placement_games > PLACEMENT_GAMES_MAX:
		return "%s: placement games are 0 to %d" % [pl.id, PLACEMENT_GAMES_MAX]
	return ""


## Why the site would refuse this [code]submit[/code], or [code]""[/code] if it would take
## it. The site's rules exactly (website-city [code]RatingSubmitInput[/code]), with one
## deliberate difference: an id with spaces round it is refused rather than trimmed, since
## the site would answer under the trimmed key and the rating would land on nobody here.
static func submit_problem(playlist_id: String, match_id: String, sides: Array, placements: Array,
		participation: Dictionary = {}) -> String:
	var pl := DotMmPlaylist.site_id_problem(playlist_id)
	if pl != "":
		return "playlist %s: %s" % [playlist_id, pl]
	if match_id.is_empty() or match_id.length() > MATCH_ID_MAX or not _is_key(match_id):
		return "match id %s: 1 to %d letters, digits, dot, underscore, colon or hyphen" % [match_id, MATCH_ID_MAX]
	if sides.size() < 2 or sides.size() > MAX_SIDES:
		return "a match has 2 to %d sides (this has %d)" % [MAX_SIDES, sides.size()]
	if placements.size() != sides.size():
		return "one placement per side (%d sides, %d placements)" % [sides.size(), placements.size()]
	for p in placements:
		if not (p is int or p is float) or float(p) != floorf(float(p)) or float(p) < 0.0 or float(p) > PLACEMENT_MAX:
			return "a placement is a whole number from 0 to %d (got %s)" % [PLACEMENT_MAX, str(p)]
	var seen := {}
	for side_v in sides:
		if not (side_v is Array or side_v is PackedStringArray):
			return "a side is a list of player keys"
		var n: int = side_v.size()
		if n < 1 or n > MAX_SIDE:
			return "a side has 1 to %d players (this has %d)" % [MAX_SIDE, n]
		for pid_v in side_v:
			var pid := str(pid_v)
			if pid.begins_with(ACCOUNT_PREFIX):
				return "an account id is not a player key; use the scoped key (see dot-stats' reporter for why)"
			if pid.is_empty() or pid.length() > KEY_MAX or not _is_key(pid):
				return "player %s: a key is 1 to %d letters, digits, dot, underscore, colon or hyphen" % [pid, KEY_MAX]
			if seen.has(pid):
				return "player %s appears more than once" % pid
			seen[pid] = true
			var part: Variant = participation.get(pid, 1.0)
			if not (part is int or part is float) or is_nan(float(part)):
				return "player %s: participation is a number from 0 to 1" % pid
	if seen.size() > MAX_PLAYERS:
		return "at most %d players in a match (this has %d)" % [MAX_PLAYERS, seen.size()]
	return ""


static func _is_key(s: String) -> bool:
	return RegEx.create_from_string("^[A-Za-z0-9._:-]+$").search(s) != null


## Files one finished match. See [method DotMatchmaker.report_result] for the arguments.
##
## Checked against the site's rules first ([method submit_problem]): a body it would
## refuse fails here with the reason, is not sent, and is not kept for retry.
func submit(playlist_id: StringName, match_id: String, sides: Array, placements: Array,
		participation: Dictionary = {}, leavers: PackedStringArray = PackedStringArray()) -> DotResult:
	var problem := submit_problem(String(playlist_id), match_id, sides, placements, participation)
	if problem != "":
		return DotResult.fail(DotError.CODE_INVALID, "the backbone would refuse this result: " + problem, match_id)
	var body_sides := []
	for side in sides:
		var rows := []
		for pid_v in side:
			var pid := str(pid_v)
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


## A 404 means one of two things, and they need opposite fixes. The site's own handlers
## answer JSON with an [code]error[/code] ("No playlist "duel" — declare it with
## rating/define first.", or the credential's app or server no longer existing). A route
## that does not exist is Next's HTML not-found page, with no JSON at all. dot-core's
## [DotHttp] keeps the first 512 bytes of the body in [member DotError.detail].
func _explain(res: DotResult, scope: String) -> DotResult:
	if res.error != null and res.error.http_status == 403:
		return res.wrap("the integration credential needs the %s scope" % scope)
	if res.error != null and res.error.http_status == 404:
		var said := site_error(res.error.detail)
		if said != "":
			return res.wrap("the backbone does not know it: " + said)
		return res.wrap("the backbone has no rating routes yet; see docs/backbone-contract.md")
	return res


## The [code]error[/code] a site handler put in its JSON body, or [code]""[/code] if the body
## is not that (an HTML page, empty, cut off).
static func site_error(body: String) -> String:
	var json := JSON.new()
	if json.parse(body) != OK:
		return ""
	var parsed: Variant = json.data
	if parsed is Dictionary and (parsed as Dictionary).get("error") is String:
		return str((parsed as Dictionary)["error"])
	return ""
