# tatami

A tiling window manager for macOS, written from scratch in Zig. No dependencies: the only
thing the build needs is the pinned Zig toolchain, and the binary links only system
frameworks.

It exists because AeroSpace kept hanging, looping and re-tiling windows it should have left
alone. See [docs/COMPLAINTS.md](docs/COMPLAINTS.md) for each complaint and the behaviour
that answers it.

## Status

| Part | State |
|---|---|
| Engine (layout, focus, workspaces, rules) | Verified by unit tests, scenario tests and a deterministic simulator |
| macOS shell (Accessibility, hot keys, displays, IPC) | Run live on one Mac (macOS 26.3, one display, 4 windows). See below. |

Checked live, each against an independent Accessibility read of every window:

- Discovery and tiling of the windows that were open, focus, swap, zoom-fullscreen.
- Workspace switch and back (frames return exactly), send to workspace, an empty workspace
  that stays empty.
- Resizing a tile with the mouse.
- Hot keys with cmd in them (focus, warp), pressed by hand.
- `tatami quit`.
- A restart, and a kill followed by a start: no window was sent a frame, and the layout,
  the split, the zoom and the focus were the same before and after.
- A second `tatami start` while one runs: refused.

Not checked live yet: hot keys that use only option or option-shift (Secure Input was on
during the trial, see [docs/INSTALL.md](docs/INSTALL.md)), `tatami rescue` with windows
actually parked, binding modes, more than one display, native tabs, sticky windows, rules,
applications that hang, and what the shell does about native fullscreen, cmd-h, windows
that are announced early, displays that are replugged and a Dock that moves.
[docs/EDGE-CASES.md](docs/EDGE-CASES.md) says for every case whether a test shows it or
only the code does.

Measured live, from the command line including process start: focus 15 to 55 ms, workspace
switch 45 to 100 ms. Almost all of it is the applications answering Accessibility calls;
the engine's share is microseconds (`tatami bench`).

## Design in one paragraph

The window manager is a pure state machine: `engine.step(event, now) -> effects`. It never
blocks, allocates or calls the operating system. A thin shell turns macOS notifications into
events and performs the effects. Because the engine is pure, the simulator can drive it
through millions of events with a hostile fake macOS (apps that hang, refuse frames, move
themselves, report late or twice) and check after every quiet moment that every window is
exactly where the engine says it should be. See [docs/DESIGN.md](docs/DESIGN.md).

## Build

```sh
./zig/download.sh                       # Zig 0.17.1, checksummed, into ./zig
./zig/zig build -Doptimize=ReleaseSafe  # zig-out/bin/tatami and zig-out/bin/tatami-sim
./zig/zig build test --summary all      # unit and scenario tests
./scripts/sim-find.sh 1 3000 5000       # seeds 1..3000, 5000 steps each
```

Apple Silicon macOS only.

## Install

```sh
./scripts/install.sh    # starts at login; see docs/INSTALL.md
```

## Use

```sh
tatami check            # permission, configuration, displays, Secure Input
tatami probe            # what Accessibility reports for every window, and how fast
tatami start --verbose  # run in the foreground
tatami focus west       # any command from the config also works from the CLI
tatami help             # every command
tatami query windows    # windows | workspaces | monitors | focus | tree | bindings | stats
tatami query tree --json  # every query also answers as JSON
tatami label editor     # name the focused window, then: focus editor, move below editor
tatami events           # follow what changes, one line per event
tatami wait 186         # return when window 186 closes
tatami reload           # re-read the config; a file with errors is rejected as a whole
tatami quit             # brings every parked window back, then exits
tatami start            # the next start finds every window in its tile, on its workspace
tatami rescue           # the same, without a running daemon
tatami bench            # engine latency per command
tatami default-config   # print the built-in configuration
```

The configuration is one file, `~/.config/tatami/tatami.conf`. Without it the built-in
[src/default.conf](src/default.conf) applies: the yabai/skhd bindings, with option-N to
switch workspace and option-shift-N to send a window there.

Keys are named as in skhd (`return`, `pageup`, `f13`, `kp5`, ...), and any key can be
given by its code: `bind alt-0x32 : ...`. A hot key that macOS refuses is named in the log.

Binding modes work as in AeroSpace: `bind mode:<name> <chord> : <command>` binds a key only
while that mode is active, and `mode <name>` switches (also `tatami mode main` from the
CLI). The default has AeroSpace's service mode on option-shift-; with esc, backspace
(close the other windows), f (float) and r (retile). A mode with no binding that leaves it
is rejected, so a key press can never strand you in one.

`toggle accordion` stacks every tile of the workspace at full size, as AeroSpace's
accordion layout does. Focus, swap and warp then step through the stack in layout order:
west and north go back, east and south go on, and from a tile of the stack `--wrap` goes
around it, never to another display. The mouse and resize leave the layout underneath alone, so toggled again
the tiles come back where they were, in their new order. `focus next` also reaches the
floating windows.

Commands can name the windows they act on, by the id that `query windows` prints or by
a label: `swap 186 logs`, `move logs right editor --ratio 30`, `zoom editor --on`,
`float 186 --bounds 0.25,0.25,0.5,0.5`. This part of the command line is modelled on
Rex's; [docs/REX.md](docs/REX.md) lists what was taken and what was not. Every command
ends with the same statuses: 0 done, 1 failed, 2 not a command, 3 no such window or
workspace, 4 the manager is not running.

Every failure that could be found in the issue trackers of AeroSpace, yabai, skhd, i3, sway,
Amethyst, Rectangle, Hammerspoon and komorebi has a row in
[docs/EDGE-CASES.md](docs/EDGE-CASES.md): what tatami does about it and the test that
shows it.

## Amethyst mode

tatami also tiles the way Amethyst does: by layouts that place the windows by their order
alone, with a main pane whose size and count you change.

```sh
tatami default-config amethyst > ~/.config/tatami/tatami.conf   # then: tatami reload
```

That configuration has Amethyst's default shortcuts (mod1 = option-shift, mod2 =
ctrl-option-shift): mod1-space and mod2-space cycle the layouts, mod1-h/l shrink and
expand the main pane, mod1-, and mod1-. change how many windows it holds, mod1-enter swaps
the focused window into it, mod1-j/k and mod2-j/k focus and swap around the layout,
mod1-w/e/r and mod2-w/e/r focus and throw to screens 1 to 3, mod1-p/n go from screen to
screen, mod1-a/s/d/f pick tall, wide, fullscreen and column, mod1-t floats a window.

| Layout | Tiles |
|---|---|
| `tall`, `tall-right` | main pane on the left (right), the others in rows beside it |
| `wide` | main pane on top, the others in columns below |
| `two-pane` | main pane and one other; the rest stack behind that one |
| `3column-left`, `3column-middle` (`middle-wide`), `3column-right` | main column there, the others shared by the two other columns |
| `widescreen-tall` | as tall, with the main pane in columns |
| `column`, `row` | one column (row) per window; the first ones are the main pane |
| `fullscreen` | every window fills the screen (the accordion) |
| `bsp` | tatami's own tree |

With `spaces native` (on in that configuration), every macOS Space is a workspace, as in
Amethyst: each Space on each display keeps its own layout, main pane count and main pane
size, macOS shows and hides the Spaces, and tatami leaves the windows of a Space that does
not show where they are. mod2-number throws the focused window to that desktop the way
Amethyst does: it holds the window by its title bar while Mission Control's "Switch to
Desktop N" shortcut is pressed, which is switched on if it was off. Do not bind those
shortcuts (ctrl-1 to ctrl-9 by default) in tatami. Which Space shows is read every 150 ms,
since macOS announces it only to AppKit applications. The Space calls are SkyLight's, as
yabai's and Amethyst's are, looked up at startup; `tatami check` says what it sees. Without
`spaces native`, workspaces are tatami's own and hidden ones are parked, as before.

A window thrown to another screen takes that screen's layout. Screens are numbered left to right, as in
Amethyst. `layouts tall wide fullscreen` in the config sets the cycle; its first layout is
where every workspace starts. Without the line the cycle has every layout, starting with
bsp, so nothing changes for an existing configuration.

The tree stays underneath every layout: `layout bsp` brings the tiles back where they
were, in their new order. Swap, warp and the mouse change the order; a drag of a tile's
edge, or `resize`, sizes the main pane. `query workspaces` shows each workspace's layout,
main count and share, and the state file keeps them over a restart.

Commands: `layout <name>` (tile the whole workspace that way), `layout next|prev`,
`main expand|shrink|more|fewer|swap|focus`, `swap next|prev`.

## Bar

An optional bar over the menu bar, with the workspaces, the focused window's title, chosen
menu-bar apps, the battery and the clock: [bar/README.md](bar/README.md). It is a separate
program in Swift that only uses tatami's command line, so tatami itself still builds with
Zig alone. Without a configuration it follows the system appearance; every colour, the
font, the logo, the clock and the tray are set in `~/.config/tatami/bar.conf`.

## Border

The focused window gets a border, as in i3: `border width 3`, `border radius 12` and
`border color 4c7899` (RRGGBB or AARRGGBB) in the config; `border width 0` turns it off.
It is a transparent window of tatami's own, ordered just above the focused window and
deaf to the mouse, so it needs no SIP change and no permission beyond Accessibility. It
hides while the window is dragged, minimized, hidden, in native fullscreen or on a
workspace that does not show. tatami becomes an accessory application to show it (no Dock
icon, no menu bar), because macOS draws nothing for a bare binary's windows.

## What it does not do

- No opacity, topmost or picture-in-picture: those need SIP disabled. The border of the
  focused window does not: it is a window of tatami's own over the focused one.
- Workspaces are virtual: hidden windows are parked in a corner, as in AeroSpace. Native
  Spaces are left alone.

## Licence

MIT or Apache-2.0, at your option: [LICENSE-MIT](LICENSE-MIT),
[LICENSE-APACHE](LICENSE-APACHE).
