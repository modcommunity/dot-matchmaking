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

## What the site rates a queue with when [code]define[/code] does not say (website-city
## [code]src/types/rating/glicko2.ts[/code]: [code]GLICKO_TAU[/code],
## [code]RATING_INACTIVITY_PERIOD_DAYS[/code], [code]RATING_MIN_PARTICIPATION[/code], and a
## leaver rated as having lost). [method define] given a config sends its own four rules, so
## these only matter for a queue declared without one. See [method parity_gaps].
const SITE_TAU := 0.5
const SITE_INACTIVITY_PERIOD_DAYS := 14.0
const SITE_MIN_PARTICIPATION := 0.25
const SITE_LEAVER_TAKES_LOSS := true

## The site's bounds on those four rules (website-city [code]RatingDefineInput[/code]). Past
## one the whole declaration is a 400.
const TAU_MAX := 3.0
const RATING_PERIOD_DAYS_MAX := 3650.0

var client: Object = null

## Where answers land. Usually the matchmaker's own store.
var store: DotMmRatingStore = null

var _pending: Array = []
## Every queue [method define] has declared, by id: the row it sent, so a result filed
## against a queue the site has not heard of yet can declare it and go again.
var _declared: Dictionary = {}
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
## call before anything is sent. Pass the matchmaker's [param config] and its rating rules
## go with every queue ([code]tau[/code], [code]ratingPeriodDays[/code],
## [code]minParticipation[/code], [code]leaverTakesLoss[/code]), so the site rates them as
## this config does. Without one they are left out, and the site keeps what it has stored
## (its defaults, for a new queue). A site from before those fields drops them unread.
##
## The rows are remembered (see [method submit]) before anything is sent, so a result filed
## while this call is still in flight can declare its queue itself.
func define(playlists: Array, config: DotMatchmakingConfig = null) -> DotResult:
	var rules_problem := config_problem(config)
	if rules_problem != "":
		return DotResult.fail(DotError.CODE_INVALID, "the backbone would refuse these rating rules: " + rules_problem)
	var rows := []
	for pl_v in playlists:
		var pl: DotMmPlaylist = pl_v
		var problem := define_problem(pl)
		if problem != "":
			return DotResult.fail(DotError.CODE_INVALID, "the backbone would refuse this playlist: " + problem,
				String(pl.id) if pl != null else "")
		var row := {
			"id": String(pl.id),
			# The site requires a name; a playlist's display name defaults to empty, and one
			# nameless queue used to have the whole declaration refused.
			"name": pl.display_name if pl.display_name.strip_edges() != "" else String(pl.id),
			"game": pl.game,
			"teams": pl.teams,
			"teamSize": pl.team_size,
			"ranked": pl.ranked,
			"placementGames": pl.placement_games,
		}
		if config != null:
			row["tau"] = config.tau
			row["ratingPeriodDays"] = config.inactivity_period_days
			row["minParticipation"] = config.min_participation
			row["leaverTakesLoss"] = config.leaver_takes_loss
		rows.append(row)
	for row in rows:
		_declared[str(row["id"])] = row
	var res := DotResult.success({"ok": true, "created": 0, "updated": 0})
	for i in range(0, rows.size(), DEFINE_BATCH):
		res = await _post(DEFINE_PATH, {"playlists": rows.slice(i, i + DEFINE_BATCH)})
		if not res.ok:
			return res
	return res


## Where [param config]'s rating rules differ from the site's defaults, one line each; empty
## when they agree. Since [method define] sends the config's rules this is no longer a
## problem to warn about: it is what a queue declared WITHOUT a config would be rated by.
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


## Why the site would refuse [param config]'s rating rules in a [code]define[/code], or
## [code]""[/code]. A null config sends no rules and is never refused.
static func config_problem(config: DotMatchmakingConfig) -> String:
	if config == null:
		return ""
	if is_nan(config.tau) or config.tau <= 0.0 or config.tau > TAU_MAX:
		return "tau is above 0 and at most %.0f (got %s)" % [TAU_MAX, str(config.tau)]
	if is_nan(config.inactivity_period_days) or config.inactivity_period_days <= 0.0 \
			or config.inactivity_period_days > RATING_PERIOD_DAYS_MAX:
		return "a rating period is above 0 and at most %.0f days (got %s)" % [
			RATING_PERIOD_DAYS_MAX, str(config.inactivity_period_days)]
	if is_nan(config.min_participation) or config.min_participation < 0.0 or config.min_participation > 1.0:
		return "minimum participation is 0 to 1 (got %s)" % str(config.min_participation)
	return ""


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
##
## A queue the site has not been told about yet (its JSON 404, [code]No playlist[/code]) is
## declared from what [method define] last sent for it, and the result goes again, once.
## A queue this backbone never declared cannot be, and that 404 is passed on as it was.
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
	var res := await _post_submit(body)
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
		var res := await _post_submit(body)
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


## One submit, and on the site's "no such playlist" a define of that one queue and one more
## submit. Not a loop: a queue the site still does not have after that (refused for the
## owner's cap, say) is the second answer, returned.
func _post_submit(body: Dictionary) -> DotResult:
	var res := await _post_raw(SUBMIT_PATH, body)
	var playlist := str(body.get("playlist", ""))
	if res.ok or not is_undeclared(res) or not _declared.has(playlist):
		return _explain(res, SCOPE_WRITE)
	DotLog.info(CHANNEL, "a result came before its queue was declared; declaring it and filing again", {
		"playlist": playlist, "match": str(body.get("matchId", "")),
	})
	var defined := await _post(DEFINE_PATH, {"playlists": [_declared[playlist]]})
	if not defined.ok:
		return defined
	return await _post(SUBMIT_PATH, body)


## Whether [param res], as the client answered it (before [method _explain]), is the site saying a playlist was never declared: its own JSON 404,
## not Next's not-found page and not a missing app or server.
static func is_undeclared(res: DotResult) -> bool:
	if res == null or res.ok or res.error == null or res.error.http_status != 404:
		return false
	return site_error(res.error.detail).begins_with("No playlist")


func _post(path: String, body: Dictionary) -> DotResult:
	return _explain(await _post_raw(path, body), SCOPE_WRITE)


func _post_raw(path: String, body: Dictionary) -> DotResult:
	if client == null or not client.has_method("post_integration"):
		return DotResult.fail(DotError.CODE_STATE, "no backbone client")
	var res: DotResult = await client.call("post_integration", path, body)
	if res.ok:
		sent += 1
	else:
		failures += 1
	return res


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
