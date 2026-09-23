class_name DotMmRating
extends RefCounted

## One person's skill in one queue: a rating, how sure we are of it, and how erratic they are.
##
## [b]Three numbers, because one is a lie.[/b] A single Elo number says a new player and a
## thousand-game veteran who both sit at 1500 are the same, and a matchmaker that believes it
## puts the newcomer against people who will flatten them for the twenty games it takes the
## number to move. [member deviation] is the missing half: how far the true skill could be
## from [member rating]. It shrinks with every game and grows back with absence, which is
## what makes a returning player's first matches move them quickly instead of slowly.
## [member volatility] is how consistently they play at their level, and is what lets a
## person who has genuinely improved climb faster than one having a lucky night.
##
## The scale is Glicko-2's public one — 1500 and 350 for somebody nobody knows — so a number
## on a website means what the same number means everywhere else that uses the system.
##
## [b]A rating is per queue, never global.[/b] A person's skill at a two-a-side mode and at
## a twelve-player free-for-all are different facts; one number for both is how a strong
## duellist lands in a team mode they have never played, in a lobby tuned for the other one.
## The store is keyed by [code](player, queue)[/code] for that reason.

## Somebody the system knows nothing about.
const DEFAULT_RATING := 1500.0
const DEFAULT_DEVIATION := 350.0
const DEFAULT_VOLATILITY := 0.06

## Deviation never falls below this.
##
## A deviation of zero is a system that is certain, and a certain system cannot move a
## person who has actually changed. Thirty is roughly where a regular player settles.
const MIN_DEVIATION := 30.0

## Deviation never rises above an unknown player's.
const MAX_DEVIATION := 350.0

var rating: float = DEFAULT_RATING
var deviation: float = DEFAULT_DEVIATION
var volatility: float = DEFAULT_VOLATILITY

## Rated matches played in this queue. Drives placement, never the maths.
var games: int = 0

## Unix seconds of the last rated match, 0 for never. What [method DotMmGlicko2.age] reads.
var last_played: int = 0


static func of(p_rating: float, p_deviation: float = DEFAULT_DEVIATION,
		p_volatility: float = DEFAULT_VOLATILITY) -> DotMmRating:
	var r := DotMmRating.new()
	r.rating = p_rating
	r.deviation = clampf(p_deviation, MIN_DEVIATION, MAX_DEVIATION)
	r.volatility = p_volatility
	return r


## The number to show a person, and to sort a leaderboard by.
##
## [b]Rating minus twice the deviation[/b] — a figure we are about 95% sure they are at
## least as good as. Showing [member rating] instead puts a player with two lucky wins at
## the top of a board above people with five hundred games, which is the complaint every
## ranked board without this gets in its first week.
func conservative() -> float:
	return rating - 2.0 * deviation


## Whether this person is still being placed.
func is_placing(placement_games: int) -> bool:
	return games < placement_games


func copy() -> DotMmRating:
	var r := DotMmRating.of(rating, deviation, volatility)
	r.games = games
	r.last_played = last_played
	return r


func to_dict() -> Dictionary:
	return {
		"rating": rating,
		"deviation": deviation,
		"volatility": volatility,
		"games": games,
		"last_played": last_played,
	}


## Reads what [method to_dict] wrote, refusing anything that would poison every later update.
##
## A NaN rating is not a bad number, it is a contagious one: every opponent it is used
## against comes out NaN too, and a whole queue's ratings go with it inside an evening.
static func from_dict(d: Dictionary) -> DotResult:
	var r := DotMmRating.new()
	r.rating = float(d.get("rating", DEFAULT_RATING))
	r.deviation = float(d.get("deviation", DEFAULT_DEVIATION))
	r.volatility = float(d.get("volatility", DEFAULT_VOLATILITY))
	r.games = int(d.get("games", 0))
	r.last_played = int(d.get("last_played", 0))

	for v in [r.rating, r.deviation, r.volatility]:
		var f := float(v)
		if is_nan(f) or is_inf(f):
			return DotResult.fail(DotError.CODE_INVALID, "a rating field is not a finite number", str(d))
	if r.volatility <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "volatility must be positive", str(d))
	if r.games < 0:
		return DotResult.fail(DotError.CODE_INVALID, "a negative number of games", str(d))

	r.deviation = clampf(r.deviation, MIN_DEVIATION, MAX_DEVIATION)
	return DotResult.success(r)


func _to_string() -> String:
	return "%.0f ±%.0f (σ %.4f, %d games)" % [rating, deviation, volatility, games]
