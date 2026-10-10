# dot-matchmaking design

Why the matchmaker is shaped the way it is, and why the obvious alternative is wrong at each point. The site half is in [backbone-contract.md](backbone-contract.md); the rules are one line each in [CLAUDE.md](../CLAUDE.md).

## What this is the half of

website-city's "matchmaking" is `PartySearch`: it finds a server for a party, loosening the party's criteria one step per pass. The site has no player queue. So this addon is the whole player-queue half. The site does rate: its `rating/*` integration routes run their own Glicko-2 ([contract](backbone-contract.md)), shaped like the `stats/*` routes dot-stats uses.

## The team extension shifts the opponent, not the player

The obvious extension rates each player against the other side's mean alone, so a 2000 on a side of 1000s "should" beat a side of 1500s and drops the most when the side loses as it was always going to. `DotMmGlicko2.rate_match` rates each player against `other_mean - (own_mean - player)`: every player on a side sees the expectation the two means predict, and moves by their own deviation. The suite's second section measures it: about 6 points against the naive 20.

## Per match, not per rating period

Glicko is designed to batch a period. Matchmakers in practice update per match because a person who just won wants to see it; the cost is volatility estimated one game at a time, which errs towards stability.

## Oldest first, and each ticket's own latency ceiling

The anchor is always the longest-waiting ticket, which is the only order that cannot starve anybody. Its skill window and quality floor are the relaxed ones; but a candidate is judged against its own latency ceiling, because a long wait is a reason for the waiter to accept a worse match, not for a newcomer to be handed eighty milliseconds.

## A party's matching rating leans to its best player

`lerp(mean, best, party_skill_blend) + premade_bonus * (size - 1)`. A party of a 2000 and a 1000 is not a 1500; matched as one, the other side meets a player far above everybody they were matched for.

## Balancing places whole tickets

`DotMmBalance` splits whole tickets (a solo player or a party) into sides: exhaustive for two sides up to `EXHAUSTIVE_LIMIT` (16) tickets, greedy plus swaps otherwise, and deterministic either way. `(mask & (1 << i)) == 0` is parenthesised deliberately: GDScript binds `&` tighter than `==` (`2 & 2 == 0` is `false`), the opposite of C, so the parentheses make the line read the same to somebody from either language.

## The accept step keeps everybody's place

A decline or a timeout cools down only the person responsible and drops their ticket (the whole party, since requeueing the rest would split it). Everybody else goes back with their original `enqueued_at`. A match with no free server falls through with nobody cooled down.

## Ratings come from the store, and the store is synchronous

`DotMatchmaker.enqueue` takes ids. A client that could send its own rating could send any rating.

A queue pass asks for every member's rating; an `await` in the middle of that is a pass that can interleave with the next. A networked store keeps a local copy and refreshes it on its own schedule (`DotMmBackbone.refresh`). `DotMmRatingStoreFile` writes a temp file and renames it over the old one, so a process killed half way leaves the previous file whole.

## The site rates

`DotMmBackbone.submit` sends the result, not numbers, and stores what comes back. The algorithm is duplicated on the site, as dot-stats' merge rule is, and both sides test the same worked example (the suite's first section).

Glickman's paper prints 1464.06 and 151.52 for its worked example, from intermediates rounded to four places; exact arithmetic gives 1464.0507 and 151.5165, which is what every exact implementation reports. The suite checks the exact figures to 0.001: a tolerance wide enough to accept the printed ones would also accept a real slip. Every other check compares ratings with each other and would still pass against a rating system with an arithmetic slip in it, which is why section 1 is the one to keep.

## What the site would refuse is refused here

A body the site rejects is a 400, and a 400 is not retried: the match is gone. So `define` and `submit` check the site's own rules first (`define_problem`, `submit_problem`, `config_problem`) and fail with the reason, and `DotMmPlaylist.validate` refuses a playlist id the site would refuse before a match is ever played in that queue. The rules and the one deliberate difference (an id with spaces round it) are in the [contract](backbone-contract.md#what-the-game-checks-before-sending).

## The config's rating rules go to the site

`tau`, `inactivity_period_days`, `min_participation` and `leaver_takes_loss` are sent per queue by `DotMmBackbone.define(playlists, config)`, so a ranked queue is rated online by the rule it is rated by offline. Details in the [contract](backbone-contract.md#rating-parity-the-configs-rules-go-with-the-declaration).

## A result can arrive before its queue

The site answers a submit for an undeclared queue with a 404 (`No playlist …`), and a 404 is not kept for retry. So the backbone remembers every row `define` sends (before sending it), and on that 404 declares the one queue again and files the result once more. Once: a second 404 is the answer. A kept result the site then refuses outright is let go by `flush` (counted in `refused`), not left at the head of the queue holding every result behind it: dot-core calls a 400 retryable, the backbone does not (`is_refused`). Details in the [contract](backbone-contract.md#what-a-404-means).

## Deliberately not here

- **Backfill.** Filling a match that lost a player is a different search (one side, one gap, a match already running) and wants its own rules about who may be dropped into a losing side.
- **Short matches.** Starting with fewer than a full set after a long wait. A decision per game, and one that changes what a rating means.
- **Role queues.** A ticket with roles is a constraint on the balancer; the balancer is where it would go.
- **An orchestrator.** `allocator` is one method. A fleet that starts servers on demand writes its own.
- **Where the service runs.** A lobby server, a hub process or, later, the site's worker. The node holds no socket so that it can be any of them.
