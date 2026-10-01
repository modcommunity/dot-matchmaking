extends Node

## Exercises dot-matchmaking with no network, no server and no wall clock.
##
## [b]The first section is the one to keep.[/b] It checks the rating update against the
## worked example printed in Glickman's Glicko-2 paper. A rating system with an arithmetic
## slip in it is wrong for everybody, by a little, with nothing failing — and every other
## check here would still pass against it, because they only compare ratings with each
## other.
##
## Everything else runs a queue against an injected clock, so "waited four minutes" is one
## assignment.
##
## [codeblock]
## godot --headless --path . res://examples/matchmaking_selftest.tscn
## [/codeblock]

const SECTIONS := 9
const CHECKS := 119

var _passed := 0
var _failed := 0
var _section_count := 0

## Captured by lambdas. A container, because a lambda captures a scalar by value.
var _now: Array[float] = [1_000_000.0]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	_line("dot-matchmaking self-test")
	_line("")

	_test_glicko_matches_the_paper()
	_test_teams()
	_test_balance()
	_test_queue()
	_test_nobody_starves()
	await _test_accept_step()
	_test_results()
	await _test_backbone()
	await _test_site_rules()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- 1 ----------------------------------------------------------------------

func _test_glicko_matches_the_paper() -> void:
	_section("Glicko-2 reproduces the worked example in Glickman's paper")

	# Section 3 of "Example of the Glicko-2 system": a 1500 ±200 player beats a 1400 ±30,
	# loses to a 1550 ±100 and loses to a 1700 ±300, with tau 0.5.
	var p := DotMmRating.of(1500.0, 200.0, 0.06)
	var after := DotMmGlicko2.update(p, [
		{"rating": 1400.0, "deviation": 30.0, "score": 1.0},
		{"rating": 1550.0, "deviation": 100.0, "score": 0.0},
		{"rating": 1700.0, "deviation": 300.0, "score": 0.0},
	], 0.5)

	# The paper prints 1464.06 from intermediates rounded to four places; unrounded, the
	# same steps give 1464.0507, which is what every exact implementation reports.
	_check(absf(after.rating - 1464.0507) < 0.001, "the new rating is 1464.05 (got %.4f)" % after.rating)
	_check(absf(after.deviation - 151.5165) < 0.001, "the new deviation is 151.52 (got %.4f)" % after.deviation)
	_check(absf(after.volatility - 0.05999) < 0.00001, "the new volatility is 0.05999 (got %.6f)" % after.volatility)
	_check(p.rating == 1500.0, "and the rating passed in was not modified")

	var idle := DotMmGlicko2.update(p, [], 0.5)
	_check(idle.rating == 1500.0, "a period with no games does not move the rating")
	_check(idle.deviation > p.deviation, "and widens the deviation, because we know less than we did")

	var away := DotMmGlicko2.age(DotMmRating.of(1800.0, 50.0), 10.0)
	_check(away.deviation > 50.0 and away.rating == 1800.0, "absence widens the deviation and leaves the rating")
	_check(DotMmGlicko2.age(DotMmRating.of(1500.0, 340.0), 1000.0).deviation <= 350.0, "and never past a stranger's")

	var known := DotMmRating.of(1800.0, 50.0)
	_check(known.conservative() == 1700.0, "the shown number is rating minus two deviations")

	var bad := DotMmRating.from_dict({"rating": NAN, "deviation": 50.0, "volatility": 0.06})
	_check(not bad.ok, "a NaN rating is refused on load, because it would spread to every opponent")


# --- 2 ----------------------------------------------------------------------

func _test_teams() -> void:
	_section("Teams: the side's expectation, the player's own step size")

	var star := DotMmRating.of(2000.0, 60.0)
	var weak_a := DotMmRating.of(1000.0, 60.0)
	var weak_b := DotMmRating.of(1000.0, 60.0)
	var opp := [DotMmRating.of(1500.0, 60.0), DotMmRating.of(1500.0, 60.0), DotMmRating.of(1500.0, 60.0)]

	# The star's side averages 1333 against 1500 and loses, as it was expected to.
	var rated := DotMmGlicko2.rate_match([[star, weak_a, weak_b], opp], [2, 1])
	var star_after: DotMmRating = (rated[0] as Array)[0]

	# The naive extension rates the star against the other side's mean alone.
	var naive := DotMmGlicko2.update(star, [{"rating": 1500.0, "deviation": 60.0, "score": 0.0}])
	var shifted := star.rating - star_after.rating
	var naive_drop := star.rating - naive.rating
	_check(shifted < naive_drop / 3.0, "a strong player on a weak side that lost as expected barely moves (%.1f against %.1f)" % [shifted, naive_drop])

	var winners: Array = rated[1]
	_check((winners[0] as DotMmRating).rating > 1500.0, "the winners go up")
	_check((winners[0] as DotMmRating).games == 1, "and have a game on the count")

	var fresh := DotMmRating.new()
	var vet := DotMmRating.of(1500.0, 40.0)
	var pair := DotMmGlicko2.rate_match([[fresh, vet], [DotMmRating.new(), DotMmRating.of(1500.0, 40.0)]], [1, 2])
	var fresh_after: DotMmRating = (pair[0] as Array)[0]
	var vet_after: DotMmRating = (pair[0] as Array)[1]
	_check(fresh_after.rating - 1500.0 > 3.0 * (vet_after.rating - 1500.0), "on one side, a newcomer moves far more than a veteran")

	var draw := DotMmGlicko2.rate_match([[DotMmRating.of(1500.0, 100.0)], [DotMmRating.of(1500.0, 100.0)]], [1, 1])
	_check(absf(((draw[0] as Array)[0] as DotMmRating).rating - 1500.0) < 0.001, "an even draw moves nobody's rating")

	var partial := DotMmGlicko2.rate_match(
		[[DotMmRating.of(1500.0, 200.0)], [DotMmRating.of(1500.0, 200.0)]], [1, 2], [[0.0], [1.0]]
	)
	var absent: DotMmRating = (partial[0] as Array)[0]
	_check(absent.rating == 1500.0 and absent.games == 0, "somebody with no participation is not rated and gains no game")

	var ffa := DotMmGlicko2.rate_match(
		[[DotMmRating.new()], [DotMmRating.new()], [DotMmRating.new()], [DotMmRating.new()]], [1, 2, 3, 4]
	)
	var first: float = ((ffa[0] as Array)[0] as DotMmRating).rating
	var last: float = ((ffa[3] as Array)[0] as DotMmRating).rating
	var second: float = ((ffa[1] as Array)[0] as DotMmRating).rating
	_check(first > second and second > last, "a free-for-all orders ratings by place")


# --- 3 ----------------------------------------------------------------------

func _test_balance() -> void:
	_section("Balancing moves whole parties and finds the best split")

	# 2000, 1000, 1600, 1400 in solos: the best split is {2000,1000} v {1600,1400}.
	var split := DotMmBalance.split([1, 1, 1, 1], [2000.0, 1000.0, 1600.0, 1400.0], 2, 2)
	_check(split.size() == 2, "four solos make two sides")
	_check(DotMmBalance.spread(split, [2000.0, 1000.0, 1600.0, 1400.0]) == 0.0, "and the split is exactly even")

	# A party of three and three solos into two sides of three: the party must be whole.
	var sizes := [3, 1, 1, 1]
	var strengths := [4500.0, 1500.0, 1500.0, 1500.0]
	var s2 := DotMmBalance.split(sizes, strengths, 2, 3)
	var party_side := -1
	for i in range(s2.size()):
		if (s2[i] as Array).has(0):
			party_side = i
	_check(party_side >= 0 and (s2[party_side] as Array).size() == 1, "a party of three fills its side alone and is not split")

	_check(DotMmBalance.split([2, 2, 2], [1.0, 1.0, 1.0], 2, 3).is_empty(), "three parties of two cannot make two sides of three")
	_check(DotMmBalance.split([1, 1, 1], [1.0, 1.0, 1.0], 2, 2).is_empty(), "and three people cannot fill four seats")

	var many := DotMmBalance.split([1, 1, 1, 1, 1, 1], [1600.0, 1500.0, 1400.0, 1600.0, 1500.0, 1400.0], 3, 2)
	_check(many.size() == 3, "three sides use the greedy path")
	_check(DotMmBalance.spread(many, [1600.0, 1500.0, 1400.0, 1600.0, 1500.0, 1400.0]) == 0.0, "and it still finds an even split here")

	var again := DotMmBalance.split([1, 1, 1, 1], [2000.0, 1000.0, 1600.0, 1400.0], 2, 2)
	_check(str(again) == str(split), "the same input gives the same sides, every time")


# --- 4 ----------------------------------------------------------------------

func _test_queue() -> void:
	_section("The queue: region first, then skill, parties whole")

	var duel := DotMmPlaylist.of(&"duel", 2, 1)
	duel.skill_window = 100.0
	duel.skill_window_growth = 10.0
	duel.min_quality = 0.0
	var q := DotMmQueue.new(duel)
	var t0 := 1000.0

	q.add(DotMmTicket.solo("a", &"duel", DotMmRating.of(1500.0, 80.0), {"eu": 30}, t0))
	q.add(DotMmTicket.solo("b", &"duel", DotMmRating.of(1550.0, 80.0), {"eu": 40}, t0 + 1.0))
	var found := q.form(t0 + 1.0)
	_check(found.size() == 1, "two close players in one region are matched at once")
	_check(q.size() == 0, "and leave the queue")
	_check((found[0] as DotMmMatch).region == "eu", "in the region they share")

	q.add(DotMmTicket.solo("c", &"duel", DotMmRating.of(1500.0, 80.0), {"eu": 30}, t0))
	q.add(DotMmTicket.solo("d", &"duel", DotMmRating.of(1900.0, 80.0), {"eu": 30}, t0))
	_check(q.form(t0).is_empty(), "400 apart is not a match at first")
	_check(q.form(t0 + 20.0).is_empty(), "nor after twenty seconds (the window is 300)")
	_check(q.form(t0 + 31.0).size() == 1, "and is after thirty-one, when the window passes 400")

	# Latency: somebody far from every region the other can use is never matched with them.
	q.add(DotMmTicket.solo("e", &"duel", DotMmRating.new(), {"eu": 30, "na": 150}, t0))
	q.add(DotMmTicket.solo("f", &"duel", DotMmRating.new(), {"na": 25}, t0))
	_check(q.form(t0 + 1.0).is_empty(), "two players with no region both reach are not matched")
	var late := q.form(t0 + 60.0)
	_check(late.size() == 1 and (late[0] as DotMmMatch).region == "na", "until the anchor's ceiling has grown to cover the other's region")

	# A candidate is judged against ITS OWN latency ceiling, not the anchor's.
	var q2 := DotMmQueue.new(duel)
	q2.add(DotMmTicket.solo("old", &"duel", DotMmRating.new(), {"eu": 150}, t0))
	q2.add(DotMmTicket.solo("new", &"duel", DotMmRating.new(), {"eu": 150}, t0 + 99.0))
	_check(q2.form(t0 + 100.0).is_empty(), "a long wait does not hand a newcomer a latency they never accepted")

	var five := DotMmPlaylist.of(&"five", 2, 3)
	five.min_quality = 0.0
	var q3 := DotMmQueue.new(five)
	var trio := [
		{"id": "p1", "rating": DotMmRating.new()},
		{"id": "p2", "rating": DotMmRating.new()},
		{"id": "p3", "rating": DotMmRating.new()},
	]
	q3.add(DotMmTicket.party("party", &"five", trio, [{"eu": 20}, {"eu": 20}, {"eu": 20}], t0))
	for n in ["s1", "s2", "s3"]:
		q3.add(DotMmTicket.solo(n, &"five", DotMmRating.new(), {"eu": 20}, t0))
	var m3: Array = q3.form(t0)
	_check(m3.size() == 1, "a party of three and three solos make a three-a-side")
	var side_with_party := -1
	var roster: Array = (m3[0] as DotMmMatch).roster()
	for i in range(roster.size()):
		if (roster[i] as Array).has("p1"):
			side_with_party = i
	var together: Array = roster[side_with_party]
	_check(together.has("p2") and together.has("p3"), "with the party on one side, together")

	var too_big := DotMmTicket.party("big", &"five", [
		{"id": "x1", "rating": DotMmRating.new()},
		{"id": "x2", "rating": DotMmRating.new()},
		{"id": "x3", "rating": DotMmRating.new()},
		{"id": "x4", "rating": DotMmRating.new()},
	], [{"eu": 1}, {"eu": 1}, {"eu": 1}, {"eu": 1}], t0)
	_check(not q3.add(too_big).ok, "a party bigger than a side is refused at the door")

	var q4 := DotMmQueue.new(duel)
	q4.add(DotMmTicket.solo("dup", &"duel", DotMmRating.new(), {"eu": 1}, t0))
	var twice := DotMmTicket.party("dup2", &"duel", [{"id": "dup", "rating": DotMmRating.new()}], [{"eu": 1}], t0)
	_check(not q4.add(twice).ok, "and one person cannot be in a queue twice")

	var worst := DotMmTicket.worst_latencies([{"eu": 20, "na": 90}, {"eu": 60}])
	_check(worst.size() == 1 and float(worst["eu"]) == 60.0, "a party's latency is its worst member's, in regions everyone reaches")


# --- 5 ----------------------------------------------------------------------

func _test_nobody_starves() -> void:
	_section("The windows widen, so the lonely edge of the ladder is served")

	var pl := DotMmPlaylist.of(&"ranked", 2, 1)
	pl.skill_window = 50.0
	pl.skill_window_growth = 5.0
	pl.skill_window_max = 800.0
	pl.min_quality = 0.9
	pl.min_quality_decay = 0.01
	var q := DotMmQueue.new(pl)
	var t0 := 5000.0
	q.add(DotMmTicket.solo("top", &"ranked", DotMmRating.of(2400.0, 40.0), {"eu": 10}, t0))
	q.add(DotMmTicket.solo("next", &"ranked", DotMmRating.of(2000.0, 40.0), {"eu": 10}, t0 + 5.0))

	var matched_at := -1.0
	for s in range(0, 300, 5):
		if not q.form(t0 + s).is_empty():
			matched_at = float(s)
			break
	_check(matched_at > 0.0, "the best player on the server is matched eventually (after %.0fs)" % matched_at)
	_check(matched_at >= 70.0, "but not before both the window and the quality bar have relaxed")

	_check(pl.window_after(10000.0) == 800.0, "the window stops at its ceiling")
	_check(pl.quality_after(10000.0) == 0.0, "and the quality bar at zero")
	_check(pl.validate().ok, "a sensible playlist validates")
	pl.skill_window_max = 10.0
	_check(not pl.validate().ok, "and one whose ceiling is below its floor does not")


# --- 6 ----------------------------------------------------------------------

func _test_accept_step() -> void:
	_section("The accept step, and who goes back to the front")

	var mm := _matchmaker()
	mm.store.put("rich", &"duel", DotMmRating.of(2500.0, 40.0))

	var ok := mm.enqueue("t-rich", &"duel", PackedStringArray(["rich"]), [{"eu": 20}])
	_check(ok.ok, "a player is queued by id")
	var t: DotMmTicket = ok.value
	_check(((t.members[0] as Dictionary)["rating"] as DotMmRating).rating == 2500.0, "at the rating the store holds, not one anybody sent")
	_check(not mm.enqueue("t-rich2", &"duel", PackedStringArray(["rich"]), [{"eu": 20}]).ok, "and cannot queue twice")
	_check(mm.cancel("t-rich"), "a ticket can be cancelled")

	var found: Array = []
	var ready: Array = []
	var cancelled: Array = []
	mm.match_found.connect(func(m: DotMmMatch, _d: float) -> void: found.append(m))
	mm.match_ready.connect(func(m: DotMmMatch) -> void: ready.append(m))
	mm.match_cancelled.connect(func(m: DotMmMatch, r: String, back: PackedStringArray) -> void: cancelled.append([m, r, back]))

	mm.enqueue("t1", &"duel", PackedStringArray(["one"]), [{"eu": 20}])
	mm.enqueue("t2", &"duel", PackedStringArray(["two"]), [{"eu": 20}])
	mm.run_pass()
	_check(found.size() == 1 and mm.pending_count() == 1, "a found match waits for everybody to accept")
	var m: DotMmMatch = found[0]
	mm.accept(m.id, "one")
	_check(ready.is_empty(), "one acceptance is not enough")
	mm.accept(m.id, "two")
	await get_tree().process_frame
	_check(ready.size() == 1, "two is")
	_check(str((ready[0] as DotMmMatch).allocation.get("address", "")) == "10.0.0.1:27015", "and the match was placed on the free server")

	# Decline: the decliner is cooled down and the other goes back in at their old time.
	_now[0] += 10.0
	mm.enqueue("t3", &"duel", PackedStringArray(["three"]), [{"eu": 20}])
	_now[0] += 5.0
	mm.enqueue("t4", &"duel", PackedStringArray(["four"]), [{"eu": 20}])
	var enqueued_three := mm.queue_for(&"duel").get_ticket("t3").enqueued_at
	mm.run_pass()
	var m2: DotMmMatch = found[1]
	mm.decline(m2.id, "four")
	_check(cancelled.size() == 1, "a decline cancels the match")
	_check((cancelled[0][2] as PackedStringArray).has("t3"), "the one who did nothing wrong is requeued")
	_check(mm.queue_for(&"duel").get_ticket("t3").enqueued_at == enqueued_three, "at the time they first queued, not now")
	var again := mm.enqueue("t4b", &"duel", PackedStringArray(["four"]), [{"eu": 20}])
	_check(not again.ok and again.error.code == DotError.CODE_RATE_LIMITED, "the decliner is kept out for a while")
	_check(again.error.retry_after > 0.0, "and told for how long")

	# Nobody answering is the same as declining, for whoever did not answer.
	mm.enqueue("t5", &"duel", PackedStringArray(["five"]), [{"eu": 20}])
	mm.run_pass()
	var m3: DotMmMatch = found[2]
	mm.accept(m3.id, "three")
	_now[0] += 60.0
	mm.run_pass()
	_check(cancelled.size() == 2, "an accept step that times out cancels the match")
	_check((cancelled[1][2] as PackedStringArray).has("t3"), "and returns whoever did accept")

	# No free server: nobody is punished, everybody goes back.
	var alloc: DotMmAllocatorList = mm.allocator
	_check(alloc.free_count("eu") == 0, "the only server is busy with the first match")
	mm.enqueue("t6", &"duel", PackedStringArray(["six"]), [{"eu": 20}])
	mm.run_pass()
	var m4: DotMmMatch = found[found.size() - 1]
	for pid in m4.player_ids():
		mm.accept(m4.id, pid)
	await get_tree().process_frame
	_check(str(cancelled[cancelled.size() - 1][1]) == "no server was free", "a match with nowhere to go falls through")
	_check((cancelled[cancelled.size() - 1][2] as PackedStringArray).size() == 2, "with both tickets back in the queue")
	alloc.release(m.id)
	_check(alloc.free_count("eu") == 1, "and a released server is free again")
	mm.queue_free()


# --- 7 ----------------------------------------------------------------------

func _test_results() -> void:
	_section("Filing a result moves the ratings, and leaving is not free")

	var mm := _matchmaker()
	var res := mm.report_result(&"duel", [["w"], ["l"]], [1, 2])
	_check(res.ok, "a result is filed")
	_check(mm.store.fetch("w", &"duel").rating > 1500.0, "the winner goes up")
	_check(mm.store.fetch("l", &"duel").rating < 1500.0, "the loser goes down")
	_check(mm.store.fetch("w", &"duel").games == 1, "and both have a game")
	_check(mm.store.fetch("w", &"duel").last_played == int(_now[0]), "stamped with when it was played")

	var team := DotMmPlaylist.of(&"team", 2, 2)
	mm.add_playlist(team)
	var quit := mm.report_result(&"team", [["a1", "a2"], ["b1", "b2"]], [1, 2], {}, PackedStringArray(["a2"]))
	_check(quit.ok, "a result with a leaver is filed")
	_check(mm.store.fetch("a2", &"team").rating < 1500.0, "a leaver on the winning side is rated as having lost")
	_check(mm.store.fetch("a1", &"team").rating > 1500.0, "while the team-mate they left behind still wins")

	var late := mm.report_result(&"team", [["c1", "c2"], ["d1", "d2"]], [1, 2], {"c2": 0.1})
	_check(late.ok and not mm.store.has_rating("c2", &"team"), "ten per cent of a match is not rated at all")

	var casual := DotMmPlaylist.of(&"casual", 2, 1)
	casual.ranked = false
	mm.add_playlist(casual)
	var none := mm.report_result(&"casual", [["x"], ["y"]], [1, 2])
	_check(none.ok and (none.value as Dictionary).is_empty(), "an unranked queue files nothing and says so")

	# A rating file survives a round trip and refuses to half-load.
	var path := "user://mm_selftest/ratings.json"
	var file := DotMmRatingStoreFile.new(path)
	file.put("z", &"duel", DotMmRating.of(1700.0, 90.0))
	var back := DotMmRatingStoreFile.new(path)
	_check(back.open().ok and back.fetch("z", &"duel").rating == 1700.0, "a rating file round-trips")
	var poisoned := DotMmRatingStore.new()
	var loaded := poisoned.load_dict({"duel|ok": {"rating": 1500.0}, "duel|bad": {"rating": INF}})
	_check(not loaded.ok and poisoned.count() == 0, "one poisoned entry refuses the whole load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	mm.queue_free()


# --- 8 ----------------------------------------------------------------------

class FakeBackbone:
	extends RefCounted
	var posts: Array = []
	var status: int = 200
	## What a failing answer's body was; DotHttp keeps it as the error's detail.
	var fail_body: String = "{}"
	var answer: Dictionary = {}
	## Answers to give first, one per post, each [status, body]; then [member status].
	var script_answers: Array = []

	func post_integration(path: String, body: Dictionary) -> DotResult:
		posts.append([path, body.duplicate(true)])
		if not script_answers.is_empty():
			var a: Array = script_answers.pop_front()
			if int(a[0]) != 200:
				return DotResult.failure(DotError.from_http(int(a[0]), str(a[1])))
			return DotResult.success(answer)
		if status != 200:
			return DotResult.failure(DotError.from_http(status, fail_body))
		return DotResult.success(answer)

	func get_integration(path: String, query: Dictionary = {}) -> DotResult:
		posts.append([path, query])
		if status != 200:
			return DotResult.failure(DotError.from_http(status, fail_body))
		return DotResult.success(answer)


func _test_backbone() -> void:
	_section("The backbone rates; the game files results and stores the answer")

	var fake := FakeBackbone.new()
	var store := DotMmRatingStore.new()
	var bb := DotMmBackbone.new(fake, store)

	var refused := await bb.submit(&"duel", "m1", [["backbone:clx123"], ["k2"]], [1, 2])
	_check(not refused.ok and fake.posts.is_empty(), "an account id is refused before anything is sent")

	fake.answer = {"ok": true, "ratings": {"k1": {"rating": 1520.0, "deviation": 180.0, "volatility": 0.06, "games": 1}}}
	var sent := await bb.submit(&"duel", "m2", [["k1"], ["k2"]], [1, 2], {"k2": 0.5}, PackedStringArray(["k2"]))
	_check(sent.ok, "a result is filed")
	var body: Dictionary = fake.posts[0][1]
	_check(str(fake.posts[0][0]) == DotMmBackbone.SUBMIT_PATH, "to the submit route")
	_check(((body["sides"] as Array)[1] as Array)[0]["leaver"] == true, "carrying the leaver")
	_check(not body.has("rating"), "and no rating at all: the site computes it")
	_check(store.fetch("k1", &"duel").rating == 1520.0, "the site's answer is stored")

	fake.status = 404
	var missing := await bb.submit(&"duel", "m3", [["k1"], ["k2"]], [1, 2])
	_check(not missing.ok and missing.error.message.contains("no rating routes yet"), "a 404 says the routes do not exist yet")
	fake.status = 503
	await bb.submit(&"duel", "m4", [["k1"], ["k2"]], [1, 2])
	_check(bb.pending_count() == 1, "a result the backbone could not take is kept for retry")
	fake.status = 200
	var flushed := await bb.flush()
	_check(flushed.ok and bb.pending_count() == 0, "and sent when it can")

	# The site's bounds, met here rather than refused there.
	fake.posts.clear()
	var many := []
	for i in range(30):
		many.append(DotMmPlaylist.of(StringName("q%d" % i), 2, 1))
	(many[0] as DotMmPlaylist).display_name = ""
	await bb.define(many)
	var first_define: Dictionary = fake.posts[0][1]
	_check(fake.posts.size() == 2 and (first_define["playlists"] as Array).size() == 25, "thirty queues are declared twenty-five at a time")
	_check(str((first_define["playlists"] as Array)[0]["name"]) == "q0", "and a queue with no display name is named by its id")
	fake.posts.clear()
	var crowd := PackedStringArray()
	for i in range(250):
		crowd.append("p%d" % i)
	await bb.refresh(&"duel", crowd)
	_check(fake.posts.size() == 3 and str(fake.posts[2][1]["players"]).split(",").size() == 50, "and two hundred and fifty ratings are read a hundred at a time")


# --- 9 ----------------------------------------------------------------------

func _test_site_rules() -> void:
	_section("What the site would refuse is refused here, with the reason")

	# Playlist ids: website-city IdentifierText, plus this addon's lowercase.
	_check(not DotMmPlaylist.of(&"ranked/5", 2, 5).validate().ok, "a playlist id with a slash is refused")
	_check(not DotMmPlaylist.of(&"-duel", 2, 1).validate().ok, "and one that starts with a hyphen")
	_check(not DotMmPlaylist.of(StringName("q".repeat(65)), 2, 1).validate().ok, "and one of 65 characters")
	_check(DotMmPlaylist.of(&"ranked.5v5:eu-1", 2, 5).validate().ok, "while dot, colon, hyphen and digits pass")

	var fake := FakeBackbone.new()
	var bb := DotMmBackbone.new(fake, DotMmRatingStore.new())
	var bad_id := DotMmPlaylist.of(&"duel", 2, 1)
	bad_id.id = &"duel/eu"
	var r := await bb.define([DotMmPlaylist.of(&"ok", 2, 1), bad_id])
	_check(not r.ok and fake.posts.is_empty(), "define with one bad id sends nothing")
	var long_name := DotMmPlaylist.of(&"duel", 2, 1)
	long_name.display_name = "n".repeat(121)
	r = await bb.define([long_name])
	_check(not r.ok and fake.posts.is_empty() and r.error.message.contains("display name"), "nor with a 121-character name, and says which")

	# Submit: keys, the 128 cap, duplicates.
	r = await bb.submit(&"duel", "m1", [["k 1"], ["k2"]], [1, 2])
	_check(not r.ok and r.error.message.contains("k 1") and r.error.message.contains("letters, digits"), "a player key with a space is refused, naming it")
	r = await bb.submit(&"duel", "m1", [["k".repeat(65)], ["k2"]], [1, 2])
	_check(not r.ok and r.error.message.contains("1 to 64"), "and a key of 65 characters")
	r = await bb.submit(&"duel", "m1", [["k1", "k2"], ["k3", "k1"]], [1, 2])
	_check(not r.ok and r.error.message.contains("k1 appears more than once"), "a player on two sides is refused")
	var big := []
	for s_i in range(3):
		var side := []
		for p_i in range(43):
			side.append("p%d_%d" % [s_i, p_i])
		big.append(side)
	r = await bb.submit(&"ffa", "m1", big, [1, 2, 3])
	_check(not r.ok and r.error.message.contains("at most 128"), "129 players in one match is refused")
	r = await bb.submit(&"duel", "m/1", [["k1"], ["k2"]], [1, 2])
	_check(not r.ok and r.error.message.contains("match id"), "a match id with a slash is refused")
	r = await bb.submit(&"Duel Eu", "m1", [["k1"], ["k2"]], [1, 2])
	_check(not r.ok and r.error.message.contains("playlist"), "and a playlist id the site would refuse")
	r = await bb.submit(&"duel", "m1", [["k1"], ["k2"]], [1])
	_check(not r.ok and r.error.message.contains("one placement per side"), "and a placement missing")
	_check(fake.posts.is_empty() and bb.pending_count() == 0, "none of which was sent, or kept to retry")
	var full := [[], []]
	for p_i in range(64):
		(full[0] as Array).append("a%d" % p_i)
		(full[1] as Array).append("b%d" % p_i)
	fake.answer = {"ok": true, "ratings": {}}
	r = await bb.submit(&"duel", "m-full", full, [1, 2])
	_check(r.ok and fake.posts.size() == 1, "while exactly 128 on two sides of 64 is sent")

	# A 404 is either the site's own answer or no route at all.
	fake.status = 404
	fake.fail_body = '{"error":"No playlist \\"duel\\" — declare it with rating/define first."}'
	r = await bb.submit(&"duel", "m5", [["k1"], ["k2"]], [1, 2])
	_check(not r.ok and r.error.message.contains("No playlist") and not r.error.message.contains("no rating routes"), "a 404 the site explained is passed on as what it said")
	r = await bb.refresh(&"duel", PackedStringArray(["k1"]))
	_check(not r.ok and r.error.message.contains("No playlist"), "on a read too")
	fake.fail_body = "<!DOCTYPE html><html><head><title>Page Not Found</title>"
	r = await bb.submit(&"duel", "m6", [["k1"], ["k2"]], [1, 2])
	_check(not r.ok and r.error.message.contains("no rating routes yet"), "and Next's HTML not-found page means the route is missing")
	fake.status = 200

	# A result filed before its queue is declared: declare it, file again, once.
	var undeclared := '{"error":"No playlist \\"duel\\" — declare it with rating/define first."}'
	var rules := DotMatchmakingConfig.new()
	rules.tau = 0.7
	var rb := FakeBackbone.new()
	var rstore := DotMmRatingStore.new()
	var rbb := DotMmBackbone.new(rb, rstore)
	rb.answer = {"ok": true, "ratings": {"k1": {"rating": 1530.0, "deviation": 170.0, "volatility": 0.06, "games": 1}}}
	await rbb.define([DotMmPlaylist.of(&"duel", 2, 1)], rules)
	rb.posts.clear()
	rb.script_answers = [[404, undeclared]]
	r = await rbb.submit(&"duel", "m-early", [["k1"], ["k2"]], [1, 2])
	var paths := rb.posts.map(func(p: Array) -> String: return str(p[0]))
	_check(r.ok and paths == [DotMmBackbone.SUBMIT_PATH, DotMmBackbone.DEFINE_PATH, DotMmBackbone.SUBMIT_PATH],
		"a 404 for an undeclared queue declares it and files the result again")
	_check(rstore.fetch("k1", &"duel").rating == 1530.0 and rbb.pending_count() == 0, "and the retried result's ratings are stored")
	var redefined: Dictionary = (rb.posts[1][1].get("playlists", [{}]) as Array)[0] if rb.posts.size() > 1 else {}
	_check(str(redefined.get("id", "")) == "duel" and is_equal_approx(float(redefined.get("tau", 0.0)), 0.7), "declaring it as define last did, rules included")
	rb.posts.clear()
	rb.script_answers = [[404, undeclared], [200, ""], [404, undeclared]]
	r = await rbb.submit(&"duel", "m-twice", [["k1"], ["k2"]], [1, 2])
	_check(not r.ok and rb.posts.size() == 3 and r.error.message.contains("No playlist"), "once: a queue still missing after that is the second answer, not a loop")
	rb.posts.clear()
	rb.script_answers = [[404, undeclared.replace("duel", "solo")]]
	r = await rbb.submit(&"solo", "m-never", [["k1"], ["k2"]], [1, 2])
	_check(not r.ok and rb.posts.size() == 1 and r.error.message.contains("No playlist"), "a queue this backbone never declared is passed on, with no define sent")
	rb.posts.clear()
	rb.script_answers = [[404, '{"error":"This app no longer exists."}']]
	r = await rbb.submit(&"duel", "m-noapp", [["k1"], ["k2"]], [1, 2])
	_check(not r.ok and rb.posts.size() == 1, "nor for the site's other 404s")
	rb.posts.clear()
	rb.script_answers = [[503, ""]]
	await rbb.submit(&"duel", "m-later", [["k1"], ["k2"]], [1, 2])
	rb.script_answers = [[404, undeclared]]
	r = await rbb.flush()
	_check(r.ok and int(r.value) == 1 and rbb.pending_count() == 0 and rb.posts.size() == 4, "and a retried result meets the same 404 the same way")

	# Rating rules: sent with the declaration, so the site rates as this config does.
	var cfg := DotMatchmakingConfig.new()
	_check(DotMmBackbone.parity_gaps(cfg).is_empty(), "the default config is the site's default")
	cfg.tau = 0.7
	cfg.inactivity_period_days = 30.0
	cfg.min_participation = 0.5
	cfg.leaver_takes_loss = false
	_check(DotMmBackbone.parity_gaps(cfg).size() == 4, "and all four differences from it are named")
	var warned: Array = []
	var sink := func(rec: Dictionary) -> void:
		if int(rec["level"]) == DotLog.Level.WARN and str(rec["channel"]) == DotMmBackbone.CHANNEL:
			warned.append(rec)
	DotLog.add_sink(sink)
	DotLog.set_channel_level(DotMmBackbone.CHANNEL, DotLog.Level.WARN)
	var old_stdout := DotLog.print_to_stdout
	DotLog.print_to_stdout = false
	fake.posts.clear()
	await bb.define([DotMmPlaylist.of(&"duel", 2, 1)], cfg)
	await bb.define([DotMmPlaylist.of(&"duel", 2, 1)])
	DotLog.print_to_stdout = old_stdout
	DotLog.clear_channel_level(DotMmBackbone.CHANNEL)
	DotLog.remove_sink(sink)
	var sent_row: Dictionary = (fake.posts[0][1]["playlists"] as Array)[0]
	_check(fake.posts.size() == 2 and is_equal_approx(float(sent_row.get("tau", 0.0)), 0.7)
		and is_equal_approx(float(sent_row.get("ratingPeriodDays", 0.0)), 30.0)
		and is_equal_approx(float(sent_row.get("minParticipation", 0.0)), 0.5)
		and sent_row.get("leaverTakesLoss") == false and sent_row.size() == 11,
		"define sends the config's four rating rules with each queue")
	_check(warned.is_empty(), "and no longer warns that the site rates by its own")
	var bare_row: Dictionary = (fake.posts[1][1]["playlists"] as Array)[0]
	_check(not bare_row.has("tau") and bare_row.size() == 7, "with no config it sends none, and the site keeps what it has")
	fake.posts.clear()
	cfg.tau = 4.0
	r = await bb.define([DotMmPlaylist.of(&"duel", 2, 1)], cfg)
	_check(not r.ok and fake.posts.is_empty() and r.error.message.contains("tau"), "a rule outside the site's bounds is refused here, naming it")


# --- helpers ------------------------------------------------------------------

func _matchmaker() -> DotMatchmaker:
	var mm := DotMatchmaker.new()
	mm.store = DotMmRatingStore.new()
	mm.clock_fn = func() -> float: return _now[0]
	var duel := DotMmPlaylist.of(&"duel", 2, 1)
	duel.min_quality = 0.0
	duel.accept_timeout_sec = 20.0
	duel.decline_cooldown_sec = 120.0
	mm.playlists = [duel]
	var alloc := DotMmAllocatorList.new()
	alloc.add_server("s1", "10.0.0.1:27015", "eu")
	mm.allocator = alloc
	add_child(mm)
	mm.set_process(false)
	return mm


func _section(title: String) -> void:
	_section_count += 1
	_line("-- %d. %s" % [_section_count, title])


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		_line("   ok    %s" % what)
	else:
		_failed += 1
		_line("   FAIL  %s" % what)


func _line(s: String) -> void:
	print(s)
