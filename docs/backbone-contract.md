# The backbone contract

website-city has no skill rating of any kind: no ELO, MMR, Glicko or TrueSkill in `src`, `prisma` or `docs` (`prisma/models/rating.prisma` is thumbs up and down on content). What the site calls "matchmaking" is `PartySearch`, which finds a **server** for a party by loosening the party's criteria one step per pass. There is no player queue.

This is what the site needs for dot-matchmaking to use it, shaped deliberately like the `stats/*` routes dot-stats already speaks, so the site-side work is a copy of a pattern rather than a new one.

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

## Where matchmaking would run on the site

The play center is the natural front door: a queue button per supported game, a ticket per player or party, and the site's own worker running passes. `DotMatchmaker` is written so that the same rules can run in a dedicated lobby server today and in the site later: it takes ids and a clock, never a socket, and its queue is a pure function of the tickets and the time.
