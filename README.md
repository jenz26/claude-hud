# Claude HUD

A tiny always-on-top widget that shows every Claude Code session running on your
machine: one row per session, with the project's colour, the chat name, and a
status dot.

*[Italiano](README.it.md)*

![Claude HUD in action](demo.gif)

Sessions appear as they start, the dot turns green when a turn ends, and blue
when one is waiting for you to approve something.

No title bar, no tabs, no taskbar entry. It sits in a corner and grows upward as
sessions come and go.

## Why

If you run Claude Code in more than one project at a time, you lose track of
which session is still working, which one finished, and — worst of all — which
one is silently waiting for you to approve a permission prompt.

Claude HUD answers that at a glance, and can play a sound when a session changes
state, so you can look away entirely.

## Requirements

- **Windows** with PowerShell 5.1 (ships with Windows 10/11) — the widget uses WPF
- **Git Bash** — the hook is a bash script. Install [Git for Windows](https://git-scm.com/download/win)
- **jq** — `winget install jqlang.jq`

If `jq` is missing the hook exits silently and writes nothing. That is
deliberate: a broken HUD must never disturb a Claude Code session.

## Install with Claude Code

You already have an agent that can do this for you. Paste the prompt below into
Claude Code and it will follow the manual steps for you — carefully, because the
prompt tells it how.

Read it before you send it. It is deliberately explicit about the one dangerous
part: your `~/.claude/settings.json` holds your own settings, and it must be
merged, never overwritten.

````text
Install Claude HUD from https://github.com/jenz26/claude-hud on this machine.

Read the repository README first and follow it. Before you start, check that
Git Bash and jq are available. If jq is missing, stop and tell me how to
install it rather than working around it.

What to do:

1. Download claude-hud.sh and claude-hud-widget.ps1 from the repo and put them
   in ~/.claude/
2. Register the seven hooks in ~/.claude/settings.json, using the JSON block
   from the README
3. Put claude-hud.cmd on my Desktop
4. Tell me how to start it and how to check that it works

Rules for step 2, because that file holds my own configuration:

- Back it up to ~/.claude/settings.json.bak before touching it
- MERGE the hooks block, do not overwrite the file. If a "hooks" section
  already exists with other events, add these alongside the existing ones and
  leave everything else exactly as it is. If one of these seven events is
  already wired to something else, stop and ask me instead of guessing
- Show me the diff before writing
- Validate the result with: jq . ~/.claude/settings.json
  If it is not valid JSON, Claude Code discards the whole file silently and
  nothing will work
- Use "$HOME" in the hook commands, not "${CLAUDE_PROJECT_DIR}". These hooks
  are global and must fire in every directory, and CLAUDE_PROJECT_DIR would
  point at whatever project happens to be open

If anything about my setup is not what the README expects, stop and ask me
instead of guessing.
````

If you would rather do it by hand, the same steps are below.

## Install by hand

Four steps. Step 2 edits a file that may already hold your own settings, so read
it before pasting.

### 1. Copy the scripts

```bash
cp claude-hud.sh claude-hud-widget.ps1 ~/.claude/
```

### 2. Register the hooks

Open `~/.claude/settings.json` and **merge** the `hooks` block below into it.

> **Merge, do not overwrite.** That file holds your own Claude Code settings. If
> it already has a `hooks` section with other events, add these alongside them —
> do not replace it. Make a backup first:
> `cp ~/.claude/settings.json ~/.claude/settings.json.bak`

```json
{
  "hooks": {
    "SessionStart":     [ { "hooks": [ { "type": "command", "shell": "bash", "async": true, "command": "bash \"$HOME/.claude/claude-hud.sh\" event" } ] } ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "shell": "bash", "async": true, "command": "bash \"$HOME/.claude/claude-hud.sh\" event" } ] } ],
    "PostToolUse":      [ { "hooks": [ { "type": "command", "shell": "bash", "async": true, "command": "bash \"$HOME/.claude/claude-hud.sh\" event" } ] } ],
    "Stop":             [ { "hooks": [ { "type": "command", "shell": "bash", "async": true, "command": "bash \"$HOME/.claude/claude-hud.sh\" event" } ] } ],
    "StopFailure":      [ { "hooks": [ { "type": "command", "shell": "bash", "async": true, "command": "bash \"$HOME/.claude/claude-hud.sh\" event" } ] } ],
    "SessionEnd":       [ { "hooks": [ { "type": "command", "shell": "bash", "async": true, "command": "bash \"$HOME/.claude/claude-hud.sh\" event" } ] } ],
    "Notification":     [ { "matcher": "permission_prompt|idle_prompt|agent_needs_input",
                            "hooks": [ { "type": "command", "shell": "bash", "async": true, "command": "bash \"$HOME/.claude/claude-hud.sh\" event" } ] } ]
  }
}
```

Then check you did not break the file:

```bash
jq . ~/.claude/settings.json
```

If that prints an error, Claude Code will silently ignore the whole file and
nothing will work. Fix it before moving on.

**Why `$HOME` and not `${CLAUDE_PROJECT_DIR}`?** These hooks are global — they
fire in every directory you open Claude Code in. `${CLAUDE_PROJECT_DIR}` would
point at whatever project is current, which is the wrong place. `$HOME` is
expanded by bash, which is the shell declared in the hook itself.

### 3. Put the launcher on your Desktop

Copy `claude-hud.cmd` to your Desktop. Rename it to something nicer if you like
— `Claude HUD.cmd` reads better under an icon.

A `.cmd` is needed because double-clicking a `.ps1` opens it in an editor instead
of running it. The launcher also passes `-ExecutionPolicy Bypass`, so it works
regardless of the machine's policy, and `-WindowStyle Hidden`, so no console
window is left behind.

### 4. Start it

Double-click the launcher. Open Claude Code somewhere and send a prompt: a row
should appear.

It does not start at login. If you want that, put a shortcut to the launcher in
`shell:startup`.

## Usage

| Gesture | Effect |
|---|---|
| Left-drag | Move the window |
| Right-click | Close the widget |

There is no title bar, so there are no window buttons — these two gestures
replace them.

Launch it twice and the second instance exits on its own; a mutex keeps it to
one.

On startup the widget **deletes leftover state files** so dead sessions do not
linger. Live sessions reappear on their next event, so the list can be short for
a few seconds.

## Status colours

| Colour | Meaning |
|---|---|
| Yellow | Turn in progress |
| Green | Turn finished |
| Red | Error |
| Blue | Waiting for a permission or input |
| Grey | Idle, or silent for more than 5 minutes |

The coloured bar on the left is the project's **Peacock** colour, read from its
`.vscode/settings.json` (`peacock.color` or `titleBar.activeBackground`). No
Peacock colour means a grey bar — that is not a fault.

After 30 minutes of silence the state file is deleted and the row disappears.
This matters because closing your editor abruptly means `SessionEnd` never fires.

## Sounds

The widget plays a sound when a session **changes state**, so you can notice a
finished turn without looking:

| Transition | Default sound |
|---|---|
| Turn finished | `Asterisk` |
| Waiting for permission or input | `Question` |
| Error | `Hand` |

The rules:

- Sounds fire **on the transition only**, not while a state persists. A session
  sitting on "finished" does not beep every second.
- **Never on first sight** of a session, so restarting the widget does not set
  off a volley for sessions that were already open.
- **One sound per tick** even if several sessions change at once; the most
  urgent wins (error, then waiting, then finished).
- Nothing when a session disappears.

Each entry takes a Windows system sound (`Asterisk`, `Beep`, `Exclamation`,
`Hand`, `Question`), a path to a `.wav`, or `''` for silence:

```powershell
$SoundDone    = ''                            # mute
$SoundWaiting = 'C:\Windows\Media\chimes.wav'
```

System sounds follow the Windows volume and sound scheme, so you can also mute
them from the mixer. `C:\Windows\Media` has `ding.wav`, `chimes.wav`,
`notify.wav`, plus the `Alarm01..10` and `Ring01..10` sets.

## Configuration

At the top of `claude-hud-widget.ps1`:

```powershell
$Anchor    = 'BottomRight'   # TopLeft | TopRight | BottomLeft | BottomRight
$MarginX   = 16              # distance from the vertical screen edge
$MarginY   = 16              # distance from the horizontal screen edge
$Width     = 340             # width; height follows the number of rows
$FontSize  = 11
$ProjWidth = 96              # width of the project column
$BackAlpha = 220             # 0 transparent, 255 opaque

$SoundDone    = 'Asterisk'
$SoundWaiting = 'Question'
$SoundError   = 'Hand'
```

The window is anchored to a corner and grows away from it, so the corner stays
put no matter how many sessions are listed.

At `$Width = 340` the title column fits about 28 characters and chat names get
ellipsised. Raise it to 420–460 if that bothers you.

Restart the widget after any change.

## How it works

Three independent pieces that talk through files:

```
Claude Code --(event)--> claude-hud.sh --(writes)--> ~/.claude/hud/<session-id>
                                                             │
                                       claude-hud-widget.ps1 (reads every second)
                                                             │
                                                       window on screen
```

The hook writes even when the widget is off, and the widget draws whatever it
finds. Neither knows about the other.

`PostToolUse` is only a heartbeat: it keeps the timestamp fresh so a busy
session does not fade to grey.

### State file format

One file per session in `~/.claude/hud/`, named after the session id. A single
line, five fields separated by `|`:

```
state|timestamp|colour|project|title
```

```
running|1719421234|#61dafb|my-api|Refactor auth middleware
```

Writes are atomic — temp file plus `mv` — so the widget can never read half a
line.

### Chat names

The title is the **chat name** Claude Code generates, read from the session
transcript in `~/.claude/projects/<project>/<session-id>.jsonl`, which contains
lines like:

```json
{"type":"ai-title","aiTitle":"Refactor auth middleware","sessionId":"..."}
```

If it is not available yet the widget falls back to the last prompt, and failing
that shows `(nuova sessione)` — see the note on language below.

### Terminal modes

`claude-hud.sh` takes three commands:

| Command | Effect |
|---|---|
| `bash ~/.claude/claude-hud.sh event` | Read by the hooks, takes JSON on stdin |
| `bash ~/.claude/claude-hud.sh once` | Draw once and exit |
| `bash ~/.claude/claude-hud.sh watch` | Redraw in the terminal every second |

`once` and `watch` are the original character-cell HUD, from before the widget
existed. They are still handy for checking state from a terminal.

## Troubleshooting

**No rows appear.** In order:

1. `ls ~/.claude/hud/` — does a file appear when you open a session? If not, the
   hooks are not firing.
2. Run `/hooks` inside Claude Code — are the seven events listed? If not,
   `~/.claude/settings.json` is not being read. Almost always it is invalid JSON,
   which Claude Code discards silently. Check with `jq . ~/.claude/settings.json`.
3. If files appear but the window is empty, the problem is in the widget. Close
   it and run `powershell -File ~/.claude/claude-hud-widget.ps1` from a terminal
   to see the errors.

**Hooks are registered but no file is written.** Almost always `jq` cannot be
found. Test the hook by hand:

```bash
echo '{"hook_event_name":"SessionStart","session_id":"test1","cwd":"C:/some/project"}' \
  | bash ~/.claude/claude-hud.sh event
cat ~/.claude/hud/test1
```

Careful when writing test payloads: Windows backslashes must be doubled.
`C:\Users` is not valid JSON — `\U` is not a legal escape — so jq rejects the
whole payload and the hook exits silently. Use `/` instead.

To force a specific jq: `HUD_JQ=/path/to/jq`.

**Two rows for the same project.** Usually two sessions really are open in that
folder: the state file is named after the session id, so two events from the
same session rewrite the same file and cannot produce two rows. The other case
is a session that was closed abruptly — the row goes grey after 5 minutes and
disappears after 30. To not wait: `rm ~/.claude/hud/<session-id>`.

**Wrong project name.** The script walks up from `cwd` looking for the first
directory with `.vscode` or `.git`. If it finds neither it uses the directory
itself.

## Notes for hackers

**`bash` on PATH is not Git Bash.** On Windows `where bash.exe` answers
`C:\Windows\System32\bash.exe`, which is WSL. Any script that launches bash must
use the full path `C:\Program Files\Git\bin\bash.exe`, or it will start Ubuntu
and find nothing.

**Do not read transcripts with `Get-Content -Tail`.** Files in
`~/.claude/projects/` reach tens of MB, but size is not the problem: every line
is a JSON event that can weigh tens of KB with attachments and tool output. In a
real transcript the last megabyte held 51 lines, and `-Tail 120` blocked for
minutes. The widget reads a fixed byte window from the end (`$TailBytes`, 1 MB),
so the cost does not depend on line length: 10–140 ms per session.

**The widget skips the redraw when nothing changed**, by comparing a signature of
the rows against the previous tick. Rebuilding the visual tree every second cost
4% of a core on an idle screen; this brings it to about 1%.

**Call `UpdateLayout()` before repositioning.** Right after replacing the rows
`ActualHeight` is still the old value, and with a bottom anchor the window drifts
off its corner. There is also a `SizeChanged` handler as a safety net.

**`$mutex` looks unused and analysers flag it.** Keep it: if the garbage
collector reclaims the Mutex, the single-instance lock is released.

**Padding in the bash script does not use `%-*s`.** Bash counts bytes, not
characters, so accented letters would shift the status-dot column. The script
sets `LC_ALL` for the same reason.

## A note on language

The inline comments in `claude-hud.sh` and `claude-hud-widget.ps1` are in
Italian, and so are the few strings the tool shows: `(nuova sessione)` for a
session whose name is not known yet, and `nessuna sessione attiva` when nothing
is running.

The comments explain the non-obvious decisions rather than restating the code,
so they are worth reading even through a translator. Pull requests translating
either the comments or the visible strings are welcome.

## License

MIT — see [LICENSE](LICENSE).
