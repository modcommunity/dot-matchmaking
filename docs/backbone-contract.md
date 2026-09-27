# The backbone contract

Before these routes, website-city had no skill rating of any kind: no ELO, MMR, Glicko or TrueSkill in `src`, `prisma` or `docs` (`prisma/models/rating.prisma` is thumbs up and down on content). What the site calls "matchmaking" is `PartySearch`, which finds a **server** for a party by loosening the party's criteria one step per pass. There is still no player queue on the site.

These routes were added for dot-matchmaking on website-city branch `feat/game-backbone` (not yet merged or deployed), shaped deliberately like the `stats/*` routes dot-stats already speaks. The site's Glicko-2 is a separate implementation and is tested against the same figures as this addon's; driven from Godot against a live dev server, the rating the site answered for a first win was 1662.3109, the same as `DotMmGlicko2.rate_match` computes locally.

One thing the site does that a client must allow for: its integration handler coerces every all-digit query value to a number. `rating/players` accepts that for its string fields; a GET should still carry its nonce in the `x-tmc-nonce` header, as `DotBackboneClient.get_integration` does.

## Routes

Under `/api/integration/v1`, integration credential, `ts` (Unix **seconds**) and `nonce` as for every integration route. dot-auth's `DotBackboneClient.post_integration` / `get_integration` do the stamping; `DotMmBackbone` calls them by name. Two new scopes: `RATING_READ`, `RATING_WRITE`.

### `POST rating/define` — `RATING_WRITE`

The queues this app runs, so the site can show them and refuse results for queues it does not know.

```json
{ "playlists": [ { "id": "ranked5", "name": "Ranked 5v5", "game": "arena", "teams": 2, "teamSize": 5, "ranked": true, "placementGames": 10 } ] }
```

### `POST rating/submit` — `RATING_WRITE`

One finished match. **No rating is sent.** The site rates.

```json
{
  "playlist": "ranked5",
  "matchId": "3f9c2a…",
  "sides": [
    [ { "player": "k7Qx…", "participation": 1.0, "leaver": false } ],
    [ { "player": "Zp2m…", "participation": 0.6, "leaver": true } ]
  ],
  "placements": [1, 2]
}
```

```json
{ "ok": true, "ratings": { "k7Qx…": { "rating": 1523.4, "deviation": 181.2, "volatility": 0.06, "games": 1, "last_played": 1790000000 } } }
```

`matchId` is idempotent: the same match filed twice rates once. `player` is the **per-scope pseudonymous key** (`play/scope-key`), never an account id — `DotMmBackbone` refuses anything shaped `backbone:…` before it leaves the server, for the reason dot-stats does.

### `GET rating/players?playlist=&players=a,b,c` — `RATING_READ`

Current ratings for the players about to be queued, so a matchmaker's store is fresh.

## The rule the site must implement, and duplicate

Glicko-2 as published (Glickman 2012, with the Illinois iteration for volatility), τ = 0.5, plus the team extension in `DotMmGlicko2.rate_match`: each player is rated against each other side as a single opponent whose rating is **that side's mean shifted by the gap between the player and their own side's mean**, with the RMS of that side's deviations; participation weights each result; a leaver is rated with their side placed last. Participation under 0.25 is not rated at all.

Both implementations must pass the same two checks, which are in `examples/matchmaking_selftest.gd` section 1 and should be copied into the site's tests:

- 1500 ±200 (σ 0.06) beating 1400 ±30 and losing to 1550 ±100 and 1700 ±300 gives **1464.0507 ±151.5165, σ 0.059996**. The paper prints 1464.06 and 151.52 because it rounds its intermediate values.
- A 2000 on a side with two 1000s, losing to three 1500s as expected, moves about 6 points, not the 20 the naive extension gives.

A rule that lives only in the game is one the site cannot check, and two implementations that disagree give a wrong number with nothing failing.

## What the game checks before sending

The site refuses a whole body with a 400 for one bad field, and a 400 is not retried, so a match lost that way is lost for good. `DotMmBackbone` therefore applies the site's own rules (`src/types/integration/rating.ts`) first and fails with the reason instead of sending:

- **Playlist ids** (`DotMmPlaylist.validate`, so also at `DotMatchmaker.add_playlist`): 1 to 64 of `A-Za-z0-9._:-`, starting with a letter or digit, plus this addon's own rule that an id is lowercase.
- **`define`** (`define_problem`): the id as above, a display name of at most 120, a game of at most 64, at most 64 sides of 64, placement games 0 to 1000.
- **`submit`** (`submit_problem`): the playlist id; a match id of 1 to 128 of `A-Za-z0-9._:-`; 2 to 64 sides of 1 to 64 players; one whole-number placement from 0 to 10000 per side; each player key 1 to 64 of `A-Za-z0-9._:-` and not `backbone:…`; no player twice; at most 128 players; no NaN participation. A refused result is not kept for retry.

One deliberate difference: the site trims an id before checking it, and the game refuses one with spaces round it. The site would answer under the trimmed key, and the rating would land on a player the game's store does not have.

## What a 404 means

Two different things, told apart by the body (`DotMmBackbone._explain`). A site handler answers JSON with an `error`: `No playlist "…" — declare it with rating/define first.` for an undeclared queue on `submit` or `players`, or that the credential's app or server no longer exists. That text is passed on. A route the deployed site does not have is Next's HTML not-found page, which is reported as "the backbone has no rating routes yet".

## Rating parity: the site rates by fixed rules

The site hard-codes what `DotMatchmakingConfig` lets a game change (`src/types/rating/glicko2.ts`: `GLICKO_TAU` 0.5, `RATING_INACTIVITY_PERIOD_DAYS` 14, `RATING_MIN_PARTICIPATION` 0.25, and a leaver always rated as having lost, in `RateSubmission`). `define` has no field for any of them, and the site's schema strips keys it does not know, so sending them would be silently ignored, not stored. A game that changes one rates one way on a self-hosted server and another way online.

Until the site takes them, `DotMmBackbone.define(playlists, config)` logs a WARN (channel `matchmaking.backbone`) when a ranked queue is declared under a config that differs, naming each difference (`DotMmBackbone.parity_gaps`), and still declares the queue. It sends nothing new. The site half of the fix: accept `tau`, `ratingPeriodDays`, `minParticipation` and `leaverTakesLoss` per playlist in `RatingDefineInput`, store them on `RatingPlaylist`, and pass them to `RateSubmission` and `RatingAt`; then `define` sends them and the warning goes.

## Where matchmaking would run on the site

The play center is the natural front door: a queue button per supported game, a ticket per player or party, and the site's own worker running passes. `DotMatchmaker` is written so that the same rules can run in a dedicated lobby server today and in the site later: it takes ids and a clock, never a socket, and its queue is a pure function of the tickets and the time.
