# dot-matchmaking

Who plays whom: Glicko-2 ratings per queue, a queue whose tolerances widen with waiting, parties placed whole, balanced sides, an accept step, a server to play on, and a result that moves the ratings. The site rates too: results go up through website-city's `rating/*` routes and the ratings come back.

Read the family [CLAUDE.md](../../CLAUDE.md) first, and [docs/backbone.md](../../docs/backbone.md) for anything that talks to website-city.

**The distributable is `addons/dot_matchmaking/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). dot-auth's `DotBackboneClient` is reached by duck typing (`post_integration`, `get_integration`). dot-server-deploy hosts a `DotMatchmaker` when its matchmaking config enables one.

## Read before

| Read | Before |
| --- | --- |
| [docs/backbone-contract.md](docs/backbone-contract.md) | changing a request, a check before sending, or retry: the three routes, their scopes and shapes, the rule both sides implement, what a 404 means, rating parity |
| [docs/design.md](docs/design.md) | changing the rating, the queue, the balancer or the accept step: the team extension, oldest first, party rating, whole tickets, the synchronous store, refusing what the site would refuse, what is deliberately not here |

## Layout

| Path | What |
| --- | --- |
| `rating/dot_mm_rating.gd` | `DotMmRating`: rating, deviation, volatility, games, last played; `conservative()` is what a board shows |
| `rating/dot_mm_glicko2.gd` | `DotMmGlicko2`: the update (the paper, step for step), `age()`, `expected()`, `rate_match()` for teams |
| `rating/dot_mm_rating_store.gd`, `_file.gd` | `DotMmRatingStore` (keyed by player and playlist, synchronous), `DotMmRatingStoreFile` (temp file and rename) |
| `queue/dot_mm_playlist.gd` | `DotMmPlaylist`: one queue's shape, party cap, widening tolerances, `validate` with the site's id rule |
| `queue/dot_mm_ticket.gd` | `DotMmTicket`: a solo player or a party, the unit of placement |
| `queue/dot_mm_balance.gd` | `DotMmBalance`: whole tickets into sides, deterministic |
| `queue/dot_mm_queue.gd`, `dot_mm_match.gd` | `DotMmQueue` (the pure `form(now)`), `DotMmMatch` (a found match with its explanation) |
| `runtime/dot_matchmaker.gd` | `DotMatchmaker`: queues, passes, accept / decline / timeout, `allocator`, `report_result` |
| `runtime/dot_mm_allocator_list.gd` | `DotMmAllocatorList`: a fixed server list, one match per server |
| `net/dot_mm_backbone.gd` | `DotMmBackbone`: `define`, `submit`, `refresh`, `flush`, and the pre-send checks |
| `dot_matchmaking_config.gd` | `DotMatchmakingConfig`: rating rules (`tau`, inactivity period, participation, leavers) |
| `examples/matchmaking_selftest.tscn` | the suite: no network, no wall clock |
| `examples/cfg_selftest.tscn` | `matchmaking.yml` through `DotMatchmakingConfig.load_cfg`: `cfg/addons/dot_matchmaking/`, `cfg/server/addons/dot_matchmaking/` over it, the flat `cfg/matchmaking.yml` shim (WARN once, removed 2026-12-31) |

Paths except `examples/` are in `addons/dot_matchmaking/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/matchmaking_selftest.tscn`. Section 1 (the paper's worked example, exact figures to 0.001) is the one to keep: every other check compares ratings with each other and would pass against an arithmetic slip. The suite is the only thing that has exercised the queue; nothing here has been found by a real queue under load or a real client. A change to a request shape wants a run against a dev site.

## Rules that bite

- `rate_match` shifts the opponent by the player's gap to their own side's mean; never rate against the other side's mean alone. [design](docs/design.md#the-team-extension-shifts-the-opponent-not-the-player)
- The anchor is the oldest ticket, but each candidate is held to its own latency ceiling. [design](docs/design.md#oldest-first-and-each-tickets-own-latency-ceiling)
- Parties are placed whole and rated toward their best player. [design](docs/design.md#a-partys-matching-rating-leans-to-its-best-player)
- A decline cools down only the decliner; everyone else keeps their `enqueued_at`; no free server cools down nobody. [design](docs/design.md#the-accept-step-keeps-everybodys-place)
- `enqueue` takes ids, never ratings; the rating store stays synchronous. [design](docs/design.md#ratings-come-from-the-store-and-the-store-is-synchronous)
- The site rates; `submit` sends results, never numbers. A change to the rule changes the site's `src/types/rating/glicko2.ts` in the same breath, and both test the same worked example. [contract](docs/backbone-contract.md#the-rule-the-site-must-implement-and-duplicate)
- Anything the site would 400 is refused before sending (`define_problem`, `submit_problem`, `config_problem`, `DotMmPlaylist.validate`); player keys are scope keys, never `backbone:…`. [contract](docs/backbone-contract.md#what-the-game-checks-before-sending)
- A `No playlist` 404 re-declares that one queue once and resubmits; a refused body is dropped from the retry queue (`is_refused`), a 401/403 or missing route stops `flush`. [contract](docs/backbone-contract.md#what-a-404-means)
- Parenthesise bitwise tests: GDScript binds `&` tighter than `==`. [design](docs/design.md#balancing-places-whole-tickets)

Deliberately not here: backfill, short matches, role queues, an orchestrator, where the service runs. [design](docs/design.md#deliberately-not-here)
