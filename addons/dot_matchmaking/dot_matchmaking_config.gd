@tool
class_name DotMatchmakingConfig
extends DotConfig

## What a matchmaker needs to be told that is not about any one queue.
##
## The per-queue numbers — windows, latency, party caps — are on [DotMmPlaylist], because
## they differ per mode and a single global value for them is how a free-for-all ends up
## as strict as a ranked queue. What is here is the machinery.

@export_group("Passes")

## Seconds between queue passes.
##
## A pass is cheap, and running it more often does not find better matches — the windows
## grow per second, not per pass. One a second is plenty; much less and a queue screen's
## "match found" lags visibly behind the moment it became possible.
@export_range(0.1, 30.0, 0.1) var pass_interval_sec: float = 1.0

## Tickets held across every queue. Past this, a new ticket is refused rather than
## accepted into a queue that will never reach it.
@export_range(1, 100000, 1) var max_tickets: int = 10000

@export_group("Ratings")

## Glicko-2's system constant: how fast volatility may change. 0.3 to 1.2; lower is steadier.
@export_range(0.2, 1.5, 0.05) var tau: float = 0.5

## Days that count as one rating period of absence.
##
## Somebody away for this long comes back with a wider deviation, and so moves faster over
## their first few matches back. Too short and a weekend makes a regular volatile; too long
## and a player back after a year is matched on a number that described somebody else.
@export_range(1.0, 365.0, 1.0) var inactivity_period_days: float = 14.0

## Where [DotMmRatingStoreFile] keeps ratings when no store is given.
@export var ratings_file: String = "user://matchmaking/ratings.json"

## Participation below this is not rated at all.
##
## A player who connected for the last thirty seconds of a match was not measured by it.
## Rating them for a twentieth of a result is the Glicko way and is what happens above
## this line; below it, the result carries so little information that recording it only
## adds a game to their count.
@export_range(0.0, 1.0, 0.05) var min_participation: float = 0.25

@export_group("Leaving")

## Whether somebody who left a ranked match early is rated as having lost it, fully.
##
## On. Otherwise leaving a match you are losing is free, and a ranked queue in which it is
## free fills with people doing it.
@export var leaver_takes_loss: bool = true


func env_prefix() -> String:
	return "DOT_MM_"


func cli_prefix() -> String:
	return "--mm-"


func validate() -> DotResult:
	if tau <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "tau must be positive")
	if pass_interval_sec <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "a pass interval of zero is a busy loop")
	return DotResult.success(null)


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("matchmaking: a pass every %.1fs, up to %d tickets" % [pass_interval_sec, max_tickets])
	out.append("  glicko-2 tau %.2f, a rating period is %.0f days idle" % [tau, inactivity_period_days])
	out.append("  participation under %.0f%% is not rated; leavers %s" % [
		min_participation * 100.0, "take the loss" if leaver_takes_loss else "are not rated",
	])
	return out
