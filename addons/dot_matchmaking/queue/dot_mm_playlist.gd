@tool
class_name DotMmPlaylist
extends Resource

## One thing a person can queue for: a game, a mode, a shape of match, and how picky to be.
##
## [b]A queue is not a game.[/b] One game ships a two-a-side, a five-a-side and a
## free-for-all, and each needs different numbers: a free-for-all of eight fills quickly
## from a wide skill band, a ranked five-a-side must not. So the unit the matchmaker
## works in is this, and a game offers as many as it has modes.
##
## Every number here widens with time rather than being one fixed tolerance. A fixed
## tolerance either starves the players at the top and bottom of the ladder — the ones
## with nobody near them — or is loose enough to make every match poor. Starting tight and
## relaxing is the only shape that serves both the crowded middle and the lonely edges.

@export_group("Identity")

## Stable id, on the wire and in the rating store. Lowercase letters, digits, dot, underscore,
## colon or hyphen, starting with a letter or digit, at most 64: the site's rule plus lowercase.
@export var id: StringName = &""

@export var display_name: String = ""

## The game this queues for — the id a server or a content pack answers to.
@export var game: String = ""

## Anything the game wants a server to know: a mode, a map pool id.
@export var mode: String = ""

@export_group("Shape")

## Sides. Two for most team games; the player count for a free-for-all of teams of one.
@export_range(2, 64, 1) var teams: int = 2

## People per side.
@export_range(1, 64, 1) var team_size: int = 5

## The largest party this queue accepts. 0 means "up to a whole team".
##
## A full premade five against five strangers is the least fair match a team game can
## make, and ranked queues commonly cap it below a whole team for that reason.
@export_range(0, 64, 1) var max_party_size: int = 0

@export_group("Skill")

## Whether this queue moves ratings. An unranked queue still MATCHES by skill — against
## its own ratings, so a casual mode is not a stomping ground — but files no results.
@export var ranked: bool = true

## Matches a newcomer plays before a rating is shown.
@export_range(0, 50, 1) var placement_games: int = 10

## The rating spread accepted at once, either side of the oldest ticket in the match.
@export_range(0.0, 2000.0, 1.0) var skill_window: float = 100.0

## How much the spread widens per second somebody has waited.
@export_range(0.0, 200.0, 0.5) var skill_window_growth: float = 5.0

## The widest the spread ever gets.
##
## A cap below "anyone" is a decision that a lonely player at the top waits longer
## rather than being fed newcomers. The default is generous; a ranked queue that
## cares more about fairness than about waiting sets it lower.
@export_range(0.0, 4000.0, 1.0) var skill_window_max: float = 800.0

## The worst match accepted, as 1 minus twice the distance of the predicted win
## chance from even: 1 is a coin toss, 0 is a foregone conclusion.
@export_range(0.0, 1.0, 0.01) var min_quality: float = 0.6

## How fast that bar comes down per second of waiting, towards zero.
@export_range(0.0, 0.1, 0.001) var min_quality_decay: float = 0.004

## How far a party's matching rating leans from its average toward its best player.
##
## A party of a 2000 and a 1000 is not a 1500: the strong one carries, and matching it as
## its average hands the other side a player far above everybody they were matched for.
## 0 is the mean, 1 is the best member.
@export_range(0.0, 1.0, 0.05) var party_skill_blend: float = 0.5

## Rating added per member beyond the first, for coordination.
##
## A premade talks and plans; the same people as strangers do not. Small, and a number
## rather than a rule, because how much a party is worth depends entirely on the game.
@export_range(0.0, 200.0, 1.0) var premade_bonus: float = 20.0

@export_group("Latency")

## Round trip accepted at once, in milliseconds, to the region a match is placed in.
@export_range(10, 1000, 5) var max_latency_ms: int = 80

## Milliseconds of extra tolerance per second waited.
@export_range(0.0, 20.0, 0.5) var latency_growth: float = 2.0

## The ceiling. Past this a match is not worth playing however long somebody waited.
@export_range(10, 2000, 5) var max_latency_cap_ms: int = 180

@export_group("Accepting")

## Seconds everybody has to accept a match that was found. 0 skips the step.
##
## The step exists because somebody queues, walks away, and costs nine other people a
## match that then cannot start. With it, the absentee is dropped and the other nine go
## back in the queue at the place they left it.
@export_range(0.0, 120.0, 1.0) var accept_timeout_sec: float = 20.0

## Seconds a person who declined or did not answer is kept out of this queue.
@export_range(0.0, 3600.0, 5.0) var decline_cooldown_sec: float = 60.0


func players_per_match() -> int:
	return teams * team_size


## The biggest party this queue takes, resolved.
func party_limit() -> int:
	if max_party_size <= 0:
		return team_size
	return mini(max_party_size, team_size)


## The spread accepted after [param waited] seconds.
func window_after(waited: float) -> float:
	return minf(skill_window + skill_window_growth * maxf(0.0, waited), skill_window_max)


## The latency ceiling after [param waited] seconds.
func latency_after(waited: float) -> float:
	return minf(max_latency_ms + latency_growth * maxf(0.0, waited), float(max_latency_cap_ms))


## The lowest match quality accepted after [param waited] seconds.
func quality_after(waited: float) -> float:
	return maxf(0.0, min_quality - min_quality_decay * maxf(0.0, waited))


## The longest id the site takes (website-city [code]src/types/integration/rating.ts[/code],
## [code]IdentifierText[/code]).
const SITE_ID_MAX := 64


## Why the site would refuse [param value] as a playlist id, or [code]""[/code] if it would
## not. The site's rule exactly: 1 to 64 characters of letters, digits, dot, underscore,
## colon or hyphen, starting with a letter or a digit. A playlist id travels in
## [code]define[/code], in every [code]submit[/code] and in every [code]players[/code] read,
## and a refusal there is a 400 nobody retries: every result for that queue is lost.
##
## The site trims first, so it would take [code]" duel"[/code] as [code]duel[/code]. This
## refuses it instead, because the answer would then come back under a different id from
## the one the game stores ratings by.
static func site_id_problem(value: String) -> String:
	if value.is_empty():
		return "an id is empty"
	if value.length() > SITE_ID_MAX:
		return "an id is at most %d characters (this is %d)" % [SITE_ID_MAX, value.length()]
	var re := RegEx.create_from_string("^[A-Za-z0-9][A-Za-z0-9._:-]*$")
	if re.search(value) == null:
		return "an id is letters, digits, dot, underscore, colon or hyphen, starting with a letter or digit"
	return ""


func validate() -> DotResult:
	if String(id) == "" or String(id) != String(id).to_lower() or String(id).contains(" "):
		return DotResult.fail(DotError.CODE_INVALID, "a playlist id must be lowercase with no spaces", String(id))
	# Lowercase is this addon's own rule; the rest is the site's, so a queue the site would
	# refuse is refused here, before a match is ever played in it.
	var site := site_id_problem(String(id))
	if site != "":
		return DotResult.fail(DotError.CODE_INVALID, "the backbone would refuse this playlist id: " + site, String(id))
	if teams < 2:
		return DotResult.fail(DotError.CODE_INVALID, "a match needs two sides", String(id))
	if team_size < 1:
		return DotResult.fail(DotError.CODE_INVALID, "a side of nobody", String(id))
	if skill_window_max < skill_window:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"the widest skill window is narrower than the first one",
			"%s: %.0f < %.0f" % [id, skill_window_max, skill_window]
		)
	if max_latency_cap_ms < max_latency_ms:
		return DotResult.fail(DotError.CODE_INVALID, "the latency cap is below the starting latency", String(id))
	return DotResult.success(null)


static func of(p_id: StringName, p_teams: int, p_team_size: int) -> DotMmPlaylist:
	var p := DotMmPlaylist.new()
	p.id = p_id
	p.display_name = String(p_id)
	p.teams = p_teams
	p.team_size = p_team_size
	return p


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("%s: %d×%d%s, parties up to %d" % [
		id, teams, team_size, " ranked" if ranked else "", party_limit(),
	])
	out.append("  skill ±%.0f +%.1f/s up to ±%.0f, quality ≥ %.2f" % [
		skill_window, skill_window_growth, skill_window_max, min_quality,
	])
	out.append("  latency %d ms +%.1f/s up to %d ms" % [max_latency_ms, latency_growth, max_latency_cap_ms])
	return out
