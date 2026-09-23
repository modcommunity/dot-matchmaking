class_name DotMmGlicko2
extends RefCounted

## Glicko-2, and the one extension a team game cannot do without.
##
## [b]The individual update is the published algorithm, unaltered.[/b] Step for step the one
## in Glickman's 2012 paper, including the Illinois iteration for the volatility — the older
## Newton iteration in the 2001 draft does not always converge, and a rating update that
## sometimes never returns is a matchmaker that sometimes freezes. The suite checks it
## against the worked example printed in the paper to four decimal places, because a
## rating system with an arithmetic slip is wrong for everybody, quietly, for ever.
##
## [b]Teams: the expectation is the TEAM's, the step size is the player's.[/b] The
## obvious team extension — rate each player against the other side's average — punishes
## a strong player for their team-mates: a 2000 on a team of 1000s "should" beat a side of
## 1500s by that arithmetic, the team loses as it was always going to, and the best player
## on the server drops the most. Here each player is rated against an opponent shifted by
## the gap between them and their own team's mean, so the expected score every player on a
## side sees is the one the two teams' means predict, while how far each one moves still
## depends on their own deviation — a newcomer moves a lot and a veteran a little, which is
## the half of Glicko that is worth keeping in a team game.
##
## [b]Per match, not per rating period.[/b] Glicko was designed to batch a period's games
## and update once. Every shipped matchmaker updates per match anyway, because a person who
## has just won wants to see it; the cost is that volatility is estimated from one game at a
## time and moves more slowly than the paper's would, which errs in the safe direction.

## Glicko-2's internal scale factor, 400 / ln(10).
const SCALE := 173.7178

## Convergence tolerance for the volatility iteration, from the paper.
const EPSILON := 0.000001

## Hard cap on volatility iterations.
##
## The Illinois method converges in a handful of steps on any real input. The cap exists
## because the input is not always real — a NaN that got into a store makes the loop
## condition false forever rather than true — and a matchmaker tick that never returns
## takes the whole queue with it.
const MAX_ITERATIONS := 100


## The chance that [param a] beats [param b], from both of their uncertainties.
##
## Used by the matchmaker to judge a proposed match, never by the update: two unknowns
## are a coin toss whatever their ratings say, and this is what says so.
static func expected(a_rating: float, a_dev: float, b_rating: float, b_dev: float) -> float:
	var phi := sqrt(pow(a_dev / SCALE, 2) + pow(b_dev / SCALE, 2))
	return 1.0 / (1.0 + exp(-_g(phi) * (a_rating - b_rating) / SCALE))


## A new rating after [param results], each [code]{rating, deviation, score, weight}[/code].
##
## [code]score[/code] is 1 for a win, 0.5 a draw, 0 a loss. [code]weight[/code], in 0..1, is
## how much of the match this person was there for: somebody who joined for the last
## minute of a twenty-minute round has not been measured by it and moves by a twentieth.
## A result with no weight counts as absence, and absence grows the deviation.
##
## [param tau] constrains how fast volatility can change. The paper suggests 0.3 to 1.2;
## smaller is steadier.
static func update(player: DotMmRating, results: Array, tau: float = 0.5) -> DotMmRating:
	var mu := (player.rating - DotMmRating.DEFAULT_RATING) / SCALE
	var phi := player.deviation / SCALE
	var sigma := player.volatility

	var inv_v := 0.0
	var sum := 0.0
	var any := false

	for r in results:
		var entry: Dictionary = r
		var w := clampf(float(entry.get("weight", 1.0)), 0.0, 1.0)
		if w <= 0.0:
			continue
		any = true
		var mu_j := (float(entry.get("rating", DotMmRating.DEFAULT_RATING)) - DotMmRating.DEFAULT_RATING) / SCALE
		var phi_j := float(entry.get("deviation", DotMmRating.DEFAULT_DEVIATION)) / SCALE
		var g := _g(phi_j)
		var e := 1.0 / (1.0 + exp(-g * (mu - mu_j)))
		inv_v += w * g * g * e * (1.0 - e)
		sum += w * g * (float(entry.get("score", 0.0)) - e)

	var out := player.copy()

	# Step 6 of the paper for somebody who did not play: only the uncertainty changes.
	if not any or inv_v <= 0.0:
		var grown := sqrt(phi * phi + sigma * sigma)
		out.deviation = clampf(grown * SCALE, DotMmRating.MIN_DEVIATION, DotMmRating.MAX_DEVIATION)
		return out

	var v := 1.0 / inv_v
	var delta := v * sum
	var new_sigma := _volatility(phi, sigma, v, delta, tau)

	var phi_star := sqrt(phi * phi + new_sigma * new_sigma)
	var new_phi := 1.0 / sqrt(1.0 / (phi_star * phi_star) + 1.0 / v)
	var new_mu := mu + new_phi * new_phi * sum

	out.rating = new_mu * SCALE + DotMmRating.DEFAULT_RATING
	out.deviation = clampf(new_phi * SCALE, DotMmRating.MIN_DEVIATION, DotMmRating.MAX_DEVIATION)
	out.volatility = new_sigma
	return out


## The deviation after [param periods] rating periods of absence.
##
## What makes a player back after three months move quickly for a few games instead of
## being matched on a number that described somebody they no longer are.
static func age(player: DotMmRating, periods: float) -> DotMmRating:
	var out := player.copy()
	if periods <= 0.0:
		return out
	var phi := player.deviation / SCALE
	var grown := sqrt(phi * phi + periods * player.volatility * player.volatility)
	out.deviation = clampf(grown * SCALE, DotMmRating.MIN_DEVIATION, DotMmRating.MAX_DEVIATION)
	return out


## Rates one finished match between any number of teams.
##
## [param teams] is an Array of Arrays of [DotMmRating]; [param placements] gives each
## team's finishing place, lower is better, equal is a draw between those two. A
## free-for-all is teams of one. [param weights], optional, mirrors [param teams] with
## each player's participation in 0..1.
##
## Returns new ratings in the same shape. Nothing passed in is modified, so a caller that
## decides afterwards not to file the match has lost nothing.
static func rate_match(teams: Array, placements: Array, weights: Array = [],
		tau: float = 0.5) -> Array:
	var means: Array[float] = []
	var devs: Array[float] = []
	for team in teams:
		var list: Array = team
		var total := 0.0
		var dev_sq := 0.0
		for p in list:
			var r: DotMmRating = p
			total += r.rating
			dev_sq += r.deviation * r.deviation
		var n := maxi(1, list.size())
		means.append(total / n)
		devs.append(sqrt(dev_sq / n))

	var out := []
	for i in range(teams.size()):
		var list: Array = teams[i]
		var rated := []
		for k in range(list.size()):
			var r: DotMmRating = list[k]
			var w := 1.0
			if i < weights.size() and k < (weights[i] as Array).size():
				w = float((weights[i] as Array)[k])

			var results := []
			for j in range(teams.size()):
				if j == i:
					continue
				var score := 0.5
				if int(placements[i]) < int(placements[j]):
					score = 1.0
				elif int(placements[i]) > int(placements[j]):
					score = 0.0
				# The shift. See the class note: every player on side i sees the
				# expectation the two sides' means predict.
				results.append({
					"rating": means[j] - (means[i] - r.rating),
					"deviation": devs[j],
					"score": score,
					"weight": w,
				})

			var updated := update(r, results, tau)
			if w > 0.0:
				updated.games = r.games + 1
			rated.append(updated)
		out.append(rated)
	return out


static func _g(phi: float) -> float:
	return 1.0 / sqrt(1.0 + 3.0 * phi * phi / (PI * PI))


## Step 5 of the paper: the Illinois iteration for the new volatility.
static func _volatility(phi: float, sigma: float, v: float, delta: float, tau: float) -> float:
	var a := log(sigma * sigma)
	var big_a := a
	var big_b := 0.0

	if delta * delta > phi * phi + v:
		big_b = log(delta * delta - phi * phi - v)
	else:
		var k := 1
		while _f(a - k * tau, delta, phi, v, a, tau) < 0.0 and k < MAX_ITERATIONS:
			k += 1
		big_b = a - k * tau

	var f_a := _f(big_a, delta, phi, v, a, tau)
	var f_b := _f(big_b, delta, phi, v, a, tau)

	var steps := 0
	while absf(big_b - big_a) > EPSILON and steps < MAX_ITERATIONS:
		steps += 1
		var c := big_a + (big_a - big_b) * f_a / (f_b - f_a)
		var f_c := _f(c, delta, phi, v, a, tau)
		if f_c * f_b <= 0.0:
			big_a = big_b
			f_a = f_b
		else:
			f_a = f_a / 2.0
		big_b = c
		f_b = f_c

	var out := exp(big_a / 2.0)
	if is_nan(out) or is_inf(out) or out <= 0.0:
		return sigma
	return out


static func _f(x: float, delta: float, phi: float, v: float, a: float, tau: float) -> float:
	var ex := exp(x)
	var num := ex * (delta * delta - phi * phi - v - ex)
	var den := 2.0 * pow(phi * phi + v + ex, 2)
	return num / den - (x - a) / (tau * tau)
