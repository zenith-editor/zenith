# zed  

A very minimal console text editor written in Zig.

## Build

zed uses POSIX interfaces not present in the stable build of zig.
Please use the latest nightly release (last tested with `zig-linux-x86_64-0.12.0-dev.3496+a2df84d0f`).

For debug builds, use the command:

```
zig build
```

For release:

```
zig build -Doptimize=ReleaseSafe
```

## Usage

By default, zed starts in text mode. You can use the following shortcuts
(`^x` means ctrl + x):

```
^q: quit
^s: save
^o: open
^b: block mode
^v: paste
^g: goto line (cmd)
^f: find (cmd)
^z: undo
```

Text navigation is done with the arrow keys. Home/End can also be used
to go to the start/end of a line.

Within block mode (accessible with ^b), you can mark a block of text by moving
your cursor and pressing Enter. Keyboard shortcuts in block mode include:

```
enter: end
^c: copy
^x: cut
del/backspace: delete a block of text
```

Shortcuts such as ^g, ^f takes you to command mode. Here, you can
enter a "command" (any acceptable input) to perform tasks.

* ^g allows you to go to a specific line by entering a number (or typing
g/G to go to the first/last line, respectively)

* ^f allows you to search through text. Use the up/down arrow keys to
search forward or backwards.

## License

Copyright (c) 2024 T.M.

BSD License. See LICENSE file for more information.
