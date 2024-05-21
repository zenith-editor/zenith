# zenith

![](/docs/preview.jpg)

A very minimal console text editor written in Zig.

## Requirements

 * A terminal emulator that supports ANSI escape sequences (currently tested with xterm on Linux)

## Build

**Supported Zig version:** 0.12.0.

For debug builds, use the command:

```
zig build
```

For release:

```
zig build -Doptimize=ReleaseSafe
```

## Usage

### Text mode

By default, zenith starts in text mode, which supports the following shortcuts (`^x` means ctrl + x):

```
^q: quit
^s: save
^o: open
^b: block mode
^v: paste
^g: goto line (cmd)
^f: find (cmd)
^z: undo
^d: duplicate line
```

Text navigation is done with the arrow keys and the PgUp/PgDown keys.
Home/End can be used to go to the start/end of a line.

### Block mode

Within block mode (accessible with `^b`), you can mark a block of text by moving your cursor and pressing Enter. Block mode supports the shortcuts:

```
enter: set end marker position
^c: copy marked block
^x: cut marked block
del/backspace: delete a block of text
>: indent
<: dedent
```

### Command mode

Shortcuts such as ^g, ^f takes you to command mode.

* `^g`: go to line
 * Enter a valid line number to go to a specific line
 * Type `g` to go to first line
 * Type `G` to go to last line

* `^f`: find and mark searched text
 * Use the up/down arrow keys to search forward or backwards.
 * `^r` to replace currently selected 
 * `^h` to replace all instances
 * `^b` to send to block mode
 * `^e` to search with regex

## License

Copyright (c) 2024 T.M.

BSD License. See LICENSE file for more information.
