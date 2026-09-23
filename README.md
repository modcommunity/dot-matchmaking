This is the **matchmaking** asset for TMC's **Dot** collection. It adds matchmaking and skill-based matchmaking to a game: players and parties queue, the queue finds fair matches in a region everybody can reach, everybody accepts, a server is found, and the result moves everybody's rating.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

## Ratings: Glicko-2, per queue

A single number says a newcomer and a thousand-game veteran on the same number are the same player, and puts the newcomer against people who will flatten them for the twenty games it takes that number to move. Glicko-2 keeps three: a **rating**, a **deviation** (how sure we are) and a **volatility** (how consistently they play). The deviation shrinks with every game and grows back with absence, so a newcomer and a returning player move quickly and a regular moves slowly.

The update is the published algorithm, step for step, and the suite checks it against the worked example in the Glicko-2 paper.

**Team games** use one extension. The obvious one, rating each player against the other side's average, punishes a strong player for weak team-mates. Here every player on a side sees the expectation that the two sides' averages predict, while how far each one moves still depends on their own deviation.

**A rating belongs to one queue.** Skill at a two-a-side mode and at a twelve-player free-for-all are different facts. The number shown to players is the rating minus two deviations — a value we are about 95% sure they are at least as good as — so two lucky wins do not top a leaderboard.

Somebody who connected for the last minute of a match is rated for a fraction of it. Somebody who **left** a ranked match is rated as having lost it, fully, because otherwise leaving a losing match is free.

## The queue: everything widens with time

```gdscript
var duel := DotMmPlaylist.of(&"duel", 2, 1)        # two sides of one
var fives := DotMmPlaylist.of(&"ranked5", 2, 5)
fives.max_party_size = 3                            # no full five-stacks against strangers

var mm := DotMatchmaker.new()
mm.playlists = [duel, fives]
mm.allocator = my_servers                           # anything with allocate(match)
add_child(mm)

mm.enqueue("t-81", &"ranked5", PackedStringArray(["ada", "bo"]), [{"eu": 31, "na": 110}, {"eu": 44}], party_id)
mm.match_found.connect(func(m, deadline): show_accept_prompt(m, deadline))
mm.match_ready.connect(func(m): send_everyone_to(m.allocation["address"]))
```

A playlist is one thing a person can queue for. The accepted skill gap, the latency ceiling and the minimum match quality all **start strict and relax the longer somebody waits**. A single fixed tolerance either starves the players at the top and bottom of the ladder, who have nobody near them, or makes every match poor.

- **Oldest ticket first.** Each pass builds a match around whoever has waited longest. That order means nobody can be left waiting forever: whoever is stuck eventually becomes the oldest, and their window grows until it reaches somebody.
- **Region first.** A ticket is only considered for a region it can reach within its **own** latency ceiling. A long wait makes the person who waited accept a worse match; it does not hand a newcomer eighty extra milliseconds.
- **Parties are never split.** A party is one ticket. Its latency to a region is its worst member's, and its matching rating leans from its average towards its best player, because a strong player carries.
- **Sides are balanced exhaustively** when that is cheap (two sides, up to sixteen tickets) and greedily otherwise, always moving whole parties.
- **Ratings come from the store, never from the client.** A client that could send its own rating could send any rating.

## Accepting, and what happens when somebody does not

A found match waits for everybody to accept. If somebody declines or does not answer, that person is kept out of the queue for a while. **Everybody else goes back in at the time they originally queued**, so they are next rather than last. A party with one member who did not answer leaves together. A match with no free server falls through without punishing anybody.

## The website

Ratings are the one number that decides who other people are made to play against, so on TMC **the website computes them, not the game server**. `DotMmBackbone` files the match result (sides, places, participation, leavers) and stores the ratings the website sends back. The website does not have rating routes yet; [docs/backbone-contract.md](docs/backbone-contract.md) specifies them in the same shape as the statistics routes it already has. Until then, and permanently for a self-hosted server, the matchmaker rates locally into a file.

## Installing

Copy `addons/dot_matchmaking/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable it in **Project → Project Settings → Plugins**.

## Dependencies

[dot-core](https://github.com/modcommunity/dot-core). Nothing else. dot-party is not a dependency — a party is a ticket with several ids on it — and dot-auth's backbone client is reached by duck typing.

## Licence

MIT. See [LICENSE](LICENSE).
