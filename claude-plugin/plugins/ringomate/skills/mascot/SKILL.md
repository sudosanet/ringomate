---
name: mascot
description: Make the RingoMate desktop mascot speak, gesture, or show an expression, or check how it is doing. Use when the user types /mascot or asks the mascot to do something.
---

# /mascot

Use the tools of the ringomate MCP server (`ringomate`). With no arguments, check `get_state` and report briefly.

- Speak: `say` (up to 40 Japanese characters or 80 characters in other languages, shown in a bubble for about 5 seconds; write it in the user's language)
- Gesture: `perform` (wave, bigWave, bow, beckon, reply, bothHandsWave, cheer, dance, nod, stretch, hop)
- Expression: `express` (smile, surprise, calm, blush, mouthOpen, eyesClosed, angry, troubled, wink; `seconds` from 0.5 to 10)
- Composed motion: `compose_motion` (for example "raise both hands in joy"; for movements that aren't one of the gestures. Takes a few seconds)
- State: `get_state`

Examples: `/mascot dance`, `/mascot say "nice work"`, `/mascot smile`.

Gestures are refused while the mascot is walking, sitting, or sleeping. If that happens, pass the result on as is and don't keep retrying.
Work status (thinking, running tools, done, and so on) is sent automatically by hooks, so don't call tools for that. Use the tools
only when the user asks, and once at big milestones (all tests passed, a long task finished).
