# zenith

![](/docs/preview.jpg)

 * **What it is:** a console-based text editor
 
   * ... that is easy to learn with familiar keyboard shortcuts
   * ... that is lightweight and requires no external dependencies
   * ... that has most of the features in a regular text editor: syntax highlighting, word wrapping, pattern matching,...
   * ... that is written in Zig
 
 * **What it is not:** an IDE

## Requirements

 * An xterm-compatible terminal emulator

## Build

<details>
<summary>*Building from source*</summary>

**Supported Zig version:** 0.12.0.

For debug builds, use the command:

```
make
```

For release:

```
make release
```

To install into a directory (i.e. `/opt`):

```
make install PREFIX="/opt"
```

</details>

You can also obtain a release tarball.

## Usage

Zenith is a modal editor. It supports the following modes:

  * Text mode (default)
  * Block mode (or text marking mode)
  * Command mode
  
You can switch from any other mode back to text mode by pressing escape.

Navigation is done with the arrow keys, page up/down, home/end keys. Editing works as you would expect from a modern non-terminal based word processor.

For more help, press `^h` (ctrl-h) to show keyboard shortcuts. Press `^h` multiple times to scroll through the help pages.

To enable syntax highlighting, copy the config directory to the appropriate location. See [documentation](docs/config.md) for details.

See also:
  
  * [Config](docs/config.md)
  * [Patterns](docs/patterns.md)

## License

Copyright (c) 2024 T.M.

BSD License. See LICENSE file for more information.
