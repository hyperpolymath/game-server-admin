# Fuzz Testing

Fuzz harnesses for Game Server Admin are not yet implemented.

## Planned Targets

- A2ML parser (`a2ml_emit.parseA2ML`) — malformed A2ML input
- Config format detection (`config_extract.detectFormat`) — arbitrary byte sequences
- Game profile parser (`game_profiles.parseA2MLProfile`) — malformed profile A2ML
- Lua config parser (`config_extract.parseLua`) — adversarial Lua table syntax

## Status

No fuzz harness exists yet. The previous `placeholder.txt` was removed as it
created a false impression of fuzz coverage.
