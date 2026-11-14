class_name DotMmBalance
extends RefCounted

## Splits whole tickets into sides as evenly as it can, and says how even that was.
##
## [b]Tickets, never people.[/b] Every assignment here moves a whole party, because the
## alternative — balance the people, then notice two friends ended up apart — is the thing
## a party exists to prevent, and it is exactly what a balancer optimising a number will do
## the moment splitting a party makes the number better.
##
## [b]Exhaustive where it is cheap, greedy where it is not.[/b] Two sides of up to sixteen
## tickets (the default [param exhaustive_limit]) is at most 2^15 assignments (the first ticket's side is fixed, since swapping
## every side is the same split), which is a few milliseconds and finds the actual best. Past
## that, or with more than two sides, it places the strongest ticket first into the weakest
## side with room and then tries every single swap that improves things. Both are
## deterministic: the same tickets in the same order always give the same sides, so a
## server and a client explaining a match to a player agree about why.

## The default for [param exhaustive_limit] ([member DotMmPlaylist.exhaustive_limit]): past this
## many tickets on two sides, stop enumerating. The cost doubles per ticket.
const EXHAUSTIVE_LIMIT := 16

## The most tickets an enumeration can index: the mask is a 64-bit int and ticket 0 is fixed.
## Not a tuning cap: past it the mask overflows, so a limit that asks for more is an error.
const EXHAUSTIVE_BITS := 63


## [param sizes] and [param strengths] are per ticket; returns an Array of Arrays of ticket
## indexes, one per side, or an empty Array when the tickets cannot be packed at all —
## three parties of two cannot make two sides of three however they are arranged.
## [param exhaustive_limit]: most tickets on two sides that are enumerated, 0 = unlimited
## (every two-sided split is enumerated; a [DotLog] error and greedy past
## [constant EXHAUSTIVE_BITS], where the mask cannot index the tickets).
static func split(sizes: Array, strengths: Array, sides: int, per_side: int,
		exhaustive_limit: int = EXHAUSTIVE_LIMIT) -> Array:
	var n := sizes.size()
	var total := 0
	for s in sizes:
		total += int(s)
	if total != sides * per_side:
		return []

	if sides == 2 and (exhaustive_limit <= 0 or n <= exhaustive_limit):
		if n <= EXHAUSTIVE_BITS:
			return _exhaustive_two(sizes, strengths, per_side)
		DotLog.error("matchmaking", "exhaustive balance asked for more tickets than a 64-bit mask holds; balancing greedily",
			{"tickets": n, "exhaustive_limit": exhaustive_limit, "most": EXHAUSTIVE_BITS})
	return _greedy(sizes, strengths, sides, per_side)


## The spread between the strongest and weakest side, in summed strength.
static func spread(assignment: Array, strengths: Array) -> float:
	var lo := INF
	var hi := -INF
	for side in assignment:
		var sum := 0.0
		for i in side:
			sum += float(strengths[int(i)])
		lo = minf(lo, sum)
		hi = maxf(hi, sum)
	return 0.0 if assignment.is_empty() else hi - lo


static func _exhaustive_two(sizes: Array, strengths: Array, per_side: int) -> Array:
	var n := sizes.size()
	var best_mask := -1
	var best_gap := INF
	var total_strength := 0.0
	for s in strengths:
		total_strength += float(s)

	# Ticket 0 is always on side 0: the mirror image of every split is the same split.
	var limit := 1 << maxi(0, n - 1)
	for m in range(limit):
		var mask := m << 1
		var count := 0
		var strength := 0.0
		for i in range(n):
			if (mask & (1 << i)) == 0:
				count += int(sizes[i])
				strength += float(strengths[i])
		if count != per_side:
			continue
		var gap := absf(strength - (total_strength - strength))
		# Strictly less, so the lowest mask wins a tie and the answer is stable.
		if gap < best_gap:
			best_gap = gap
			best_mask = mask

	if best_mask < 0:
		return []

	var a := []
	var b := []
	for i in range(n):
		if (best_mask & (1 << i)) == 0:
			a.append(i)
		else:
			b.append(i)
	return [a, b]


static func _greedy(sizes: Array, strengths: Array, sides: int, per_side: int) -> Array:
	var order := range(sizes.size())
	# Biggest parties first, since they are the hard ones to fit; then strongest; then
	# index, so equal tickets always land the same way.
	order.sort_custom(func(x: int, y: int) -> bool:
		if int(sizes[x]) != int(sizes[y]):
			return int(sizes[x]) > int(sizes[y])
		if float(strengths[x]) != float(strengths[y]):
			return float(strengths[x]) > float(strengths[y])
		return x < y
	)

	var out := []
	var fill: Array[int] = []
	var power: Array[float] = []
	for _s in range(sides):
		out.append([])
		fill.append(0)
		power.append(0.0)

	for i in order:
		var pick := -1
		for s in range(sides):
			if fill[s] + int(sizes[i]) > per_side:
				continue
			if pick < 0 or power[s] < power[pick]:
				pick = s
		if pick < 0:
			return []
		(out[pick] as Array).append(i)
		fill[pick] += int(sizes[i])
		power[pick] += float(strengths[i])

	_improve_by_swaps(out, sizes, strengths)
	return out


## Swaps equal-sized tickets between sides while that narrows the spread.
static func _improve_by_swaps(out: Array, sizes: Array, strengths: Array) -> void:
	var improved := true
	var rounds := 0
	while improved and rounds < 64:
		improved = false
		rounds += 1
		var before := spread(out, strengths)
		for a in range(out.size()):
			for b in range(a + 1, out.size()):
				var side_a: Array = out[a]
				var side_b: Array = out[b]
				for ia in range(side_a.size()):
					for ib in range(side_b.size()):
						var x: int = side_a[ia]
						var y: int = side_b[ib]
						if int(sizes[x]) != int(sizes[y]):
							continue
						side_a[ia] = y
						side_b[ib] = x
						var after := spread(out, strengths)
						if after + 0.0001 < before:
							before = after
							improved = true
						else:
							side_a[ia] = x
							side_b[ib] = y
