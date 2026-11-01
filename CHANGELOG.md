# Changelog

## 2.0.1

Bug fixes.

- A kill reported by both the RvR kill message and "You have slain ..." now
  plays its announcer and overlay once, not twice.
- Kill streaks (double kill and up) are timed reliably, including around
  midnight.
- Overlays whose victim cannot be placed on screen stay where it was last seen
  instead of jumping to another enemy.
- /ufx works even when LibSlash loads after UnrealFX.
- Healing a player or pet no longer prepares a kill overlay on them.
- Rare Lua errors on empty or unexpected combat log lines are gone.
- Kill effects land on the right enemy more often.

Performance improvements.

- Less work on every combat hit and every frame, which helps in big fights.
- The sound helper (UnrealFX.exe) reads only new log lines and checks for the
  game less often.

Other changes.

- One short chat line at login. Use /ufx status to see your alert settings.

## 2.0.0

- First UnrealFX release: UT-style kill announcer with world-attached overlays.
