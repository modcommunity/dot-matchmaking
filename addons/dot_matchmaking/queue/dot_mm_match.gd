class_name DotMmMatch
extends RefCounted

## A match the queue found: who, on which side, where, and how good a match it is.
##
## Carries its own explanation. "Why did I get this match" is the question every
## matchmaker is asked, and the answer — how long the oldest ticket had waited, how wide
## the window had grown, what the predicted odds were — is only knowable at the moment it
## was made. [method describe] is that moment, written down.

var id: String = ""
var playlist: StringName = &""
var region: String = ""

## One Array of [DotMmTicket] per side.
var sides: Array = []

## 1 is a coin toss, 0 a foregone conclusion. See [member DotMmPlaylist.min_quality].
var quality: float = 0.0

## Chance side 0 wins, for a two-sided match; -1 otherwise.
var win_chance: float = -1.0

## The skill window the anchor ticket had grown to when this was made.
var window: float = 0.0

## Seconds the longest-waiting ticket in it had waited.
var longest_wait: float = 0.0

## Unix seconds this was made.
var formed_at: float = 0.0

## Where the game was put, once something allocated it: an address, a reservation id.
var allocation: Dictionary = {}


func tickets() -> Array:
	var out := []
	for side in sides:
		out.append_array(side as Array)
	return out


func ticket_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for t in tickets():
		out.append((t as DotMmTicket).id)
	return out


func player_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for t in tickets():
		out.append_array((t as DotMmTicket).member_ids())
	return out


## Player ids per side, which is what a game server needs to seat people.
func roster() -> Array:
	var out := []
	for side in sides:
		var ids := PackedStringArray()
		for t in side:
			ids.append_array((t as DotMmTicket).member_ids())
		out.append(Array(ids))
	return out


func describe() -> Dictionary:
	return {
		"id": id,
		"playlist": String(playlist),
		"region": region,
		"sides": roster(),
		"quality": snappedf(quality, 0.001),
		"win_chance": snappedf(win_chance, 0.001),
		"window": snappedf(window, 0.1),
		"longest_wait": snappedf(longest_wait, 0.1),
		"allocation": allocation,
	}
