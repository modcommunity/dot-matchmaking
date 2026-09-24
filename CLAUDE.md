# dot-matchmaking

Who plays whom: Glicko-2 ratings per queue, a queue whose tolerances widen with waiting, parties placed whole, balanced sides, an accept step, a server to play on, and a result that moves the ratings.

**The distributable is `addons/dot_matchmaking/`.** It requires [dot-core](../dot-core), a separate repository, and nothing else.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## What existed, and what did not

website-city's "matchmaking" is `PartySearch`: it finds a **server** for a party, loosening the party's criteria one step per pass. There is no player queue and **no skill rating anywhere** in the site. So this addon is the whole player-queue half. Its backbone half ([docs/backbone-contract.md](docs/backbone-contract.md)) was then added to the site, shaped like the `stats/*` routes dot-stats uses, on a branch not yet deployed; the site's own Glicko-2 agrees with this one to four places on a live result.

## The pieces

| | |
| --- | --- |
| `DotMmRating` | rating, deviation, volatility, games, last played. `conservative()` is what a board shows. |
| `DotMmGlicko2` | The update (the paper, step for step), `age()` for absence, `expected()` for match quality, `rate_match()` for teams. |
| `DotMmRatingStore`, `DotMmRatingStoreFile` | Keyed by `(player, playlist)`. Synchronous on purpose. The file store writes a temp file and renames it. |
| `DotMmPlaylist` | One queue: shape, party cap, and the skill / latency / quality tolerances with their growth and ceilings. |
| `DotMmTicket` | A solo player or a party. The unit of placement. |
| `DotMmBalance` | Whole tickets into sides. Exhaustive for two sides up to 16 tickets, greedy plus swaps otherwise. Deterministic. |
| `DotMmQueue` | One playlist's queue and the pure function `form(now)`. |
| `DotMmMatch` | A found match, with its own explanation: window, wait, win chance, quality. |
| `DotMatchmaker` | The node: queues, passes, accept / decline / timeout, allocation, `report_result`. |
| `DotMmAllocatorList` | A fixed server list, one match per server. The allocator a small deployment actually has. |
| `DotMmBackbone` | Results up, ratings down, against the proposed routes. |

## Decisions

### The team extension shifts the opponent, not the player

The obvious extension rates each player against the other side's mean alone, so a 2000 on a side of 1000s "should" beat a side of 1500s and drops the most when the side loses as it was always going to. `rate_match` rates each player against `other_mean - (own_mean - player)`: every player on a side sees the expectation the two means predict, and moves by their own deviation. Section 2 measures it: about 6 points against the naive 20.

### Per match, not per rating period

Glicko is designed to batch a period. Every shipped matchmaker updates per match because a person who just won wants to see it; the cost is volatility estimated one game at a time, which errs towards stability.

### Oldest first, and each ticket's own latency ceiling

The anchor is always the longest-waiting ticket, which is the only order that cannot starve anybody. Its skill window and quality floor are the relaxed ones; but a candidate is judged against **its own** latency ceiling, because a long wait is a reason for the waiter to accept a worse match, not for a newcomer to be handed eighty milliseconds.

### A party's matching rating leans to its best player

`lerp(mean, best, party_skill_blend) + premade_bonus * (size - 1)`. A party of a 2000 and a 1000 is not a 1500; matched as one, the other side meets a player far above everybody they were matched for.

### The accept step keeps everybody's place

A decline or a timeout cools down only the person responsible and drops their ticket (the whole party, since requeueing the rest would split it). Everybody else goes back with their original `enqueued_at`. A match with no free server falls through with **nobody** cooled down.

### Ratings come from the store

`enqueue` takes ids. A client that could send its own rating could send any rating.

### The site rates

`DotMmBackbone.submit` sends the result, not numbers, and stores what comes back. The algorithm is duplicated on the site, as dot-stats' merge rule is, and both sides test the same worked example.

### The store is synchronous

A queue pass asks for every member's rating; an `await` in the middle of that is a pass that can interleave with the next. A networked store keeps a local copy and refreshes it on its own schedule (`DotMmBackbone.refresh`).

## What building it found

**The paper's own example does not reproduce to the printed decimals, and that is the paper.** Glickman prints 1464.06 and 151.52 from intermediates rounded to four places; exact arithmetic gives 1464.0507 and 151.5165, which is what every exact implementation reports. The suite checks the exact figures to 0.001 — a tolerance wide enough to accept the printed ones would also accept a real slip.

Nothing else failed on the first run: all 85 checks passed, and the only change needed was the check count the suite asserts, which had been miscounted by hand. That is recorded because it is unusual here, and because it means **nothing in this addon has yet been found by running a real queue under load or a real client** — the queue has only met the suite.

`(mask & (1 << i)) == 0` is parenthesised deliberately. GDScript binds `&` tighter than `==` — measured: `2 & 2 == 0` is `false`, a bool — which is the opposite of C, so the parentheses make the line read the same to somebody from either language.

## Things deliberately not here

- **Backfill.** Filling a match that lost a player is a different search (one side, one gap, a match already running) and wants its own rules about who may be dropped into a losing side.
- **Short matches.** Starting with fewer than a full set after a long wait. A decision per game, and one that changes what a rating means.
- **Role queues.** A ticket with roles is a constraint on the balancer; the balancer is where it would go.
- **An orchestrator.** `allocator` is one method. A fleet that starts servers on demand writes its own.
- **Where the service runs.** A lobby server, a hub process or, later, the site's worker. The node holds no socket so that it can be any of them.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 120 godot --headless --path . res://examples/matchmaking_selftest.tscn
```

8 sections, 85 checks, no network and no wall clock. **Section 1 is the one to keep**: every other check compares ratings with each other and would still pass against a rating system with an arithmetic slip in it.
