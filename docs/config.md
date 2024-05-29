# Config

Zenith looks up the main `zenith.conf` config file in the following directories:

  * **Linux, BSD:**
    1. `$XDG_CONFIG_HOME/zenith/zenith.conf`
    2. `$HOME/.config/zenith/zenith.conf`

Zenith uses a custom dialect of [TOML](https://toml.io/en/v1.0.0) to store configuration data. This dialect only supports pairs of keys and values, table headers in square brackets, and array headers in double square brackets. Only strings, integers (signed 64-bit), booleans and arrays are supported. In addition, the following extensions are supported:

  1. Zig-style multi-line strings:
  
  Example of the string `"a\nb"` represented under the new multi-line syntax:

```
key=\\a
    \\b
```

Paths are specified relative to the directory containing the `zenith.conf` file.

## Example config

```
tab-size = 2
use-tabs = false
use-native-clipboard = true
show-line-numbers = true
wrap-text = true

[[highlight.markdown]]
path = "highlight/md.conf"
extension = ".md"

[[highlight.zig]]
path = "highlight/zig.conf"
extension = ".zig"
```

## Config keys

### General

  * `tab-size` (since *0.3.0*):
  
  (int) Sets the number of space characters inserted when pressing the tab key or adjusting the indentation level of a text block (in mark mode). The tab size is the count of these space characters (ASCII code 32). Ignored if `use-tabs` is set to true.

  * `use-tabs` (since *0.3.0*):
  
  (bool) If set to true, tabs (ASCII code 9) will be used for indentation instead of spaces.
  
  * `use-native-clipboard` (since *0.3.0*):
  
  (bool) If set to true, the native system clipboard will be utilized instead of zenith's session-specific clipboard. In Linux environments, this requires `xclip` to be installed and the terminal to be ran in X11.

  * `show-line-numbers` (since *0.3.0*):
  
  (bool) Sets whether to show line numbers or not.
  
  * `wrap-text` (since *0.3.0*):
  
  (bool) Sets whether to wrap text or not.
  
  * `undo-memory-limit` (since *0.3.0*):
  
  (int) Specifies the maximum amount of memory (in bytes) allocated to the undo heap for managing text actions. When editing text, actions are recorded by allocating memory into the undo heap. If the editor attempts to record an action that causes the undo heap to exceed the limit specified by this configuration, the editor will display an error message. Default is *4 GiB*.

  * `escape-time` (since *0.3.0*):
  
  (int) This configuration determines the time delay (in milliseconds) for recognizing the escape key from stdin. In Xterm-compatible terminals, this configuration is used to resolve ambiguity in parsing escape sequences, where a single escape character is followed by standard printable characters. It operates similarly to the 'escape-time' setting in tmux. Default is *20 ms*.

  * `update-cursor-on-navigate` (since *0.4.0*):
  
  (bool) If set to true, when the user navigates in the text marking mode, the start/end point will automatically be set to the current position of the cursor.

### Terminal feature flags

The following configuration keys control the use of specific terminal features by the editor. When the keys are set to true, the editor will use these features *if* the terminal supports them. Setting them to false means these features will not be used. The default setting for all configuration keys is *true*.

  * `force-bracketed-paste`: bracketed paste
  * `force-alt-screen-buf`: use the alternate screen buffer instead of the normal screen buffer.
  * `force-alt-scroll-mode`: if set to true and the alternate screen buffer is used, then scrolling will be enabled
  * `force-mouse-tracking`: enables mouse tracking (required for detecting clicks and scrolls)

## Syntax highlighting config

Syntax highlighting is defined by external configuration files. These files may contain collections of patterns that the editor uses to recognize various syntax elements. Zenith reads every highlighting configuration declared in `zenith.conf`, which looks like this:

```
[[highlight.zig]]
path = "highlight/zig.conf"
extension = ".zig"
```

where `path` is the location of the syntax highlighting file relative to the parent directory of `zenith.conf`, and `extension` tells the text editor that this config should be used for files of this file extension.

Within the syntax highlighting file, you may specify the token types of the language being highlighted. Token types may be declared like in the following example:

```
[[string]]
pattern=\\".-"
color="blue"
```

In this example, a "string" token type is defined, which matches any text with the pattern `".-"` (see [Patterns](./patterns.md)). The token is specified to be the color blue.

## Config keys

  * `pattern` (since *0.3.0*):
  
  (string) The pattern of the token
  
  * `flags` (since *0.3.0*):
  
  (string) Short code for flags used by pattern. (see [Patterns#Flags](./patterns.md#flags))
    
  * `color` (since *0.3.0*):
  
  (string or int) The color of the token

  * `bold` (since *0.3.0*):
  
  (bool) Whether the token should be bold
  
  * `italic` (since *0.3.0*):
  
  (bool) Whether the token should be italic
  
  * `underline` (since *0.3.0*):
  
  (bool) Whether the token should be underline

  * `promote:...` (since *0.3.0*):
  
  (array of strings) List of raw-text tokens to promote to token type ...

## Example

Here is an example of a highlighting config file for Zig:

```
[[string]]
pattern=\\".-"
color="blue"

[[char]]
pattern=\\'(.|\\.)'
color="blue"

[[keyword]]
color="cyan"
bold=true

[[value]]
color="purple"

[[number]]
pattern=\\[0-9]+(\.[0-9]*)?
color="purple"

[[primitive-type]]
color="blue"

[[identifier]]
pattern=\\[a-zA-Z_][a-zA-Z0-9_]*
color="dark-yellow"
promote:keyword=["addrspace","align","allowzero","and","anyframe","anytype","asm","async","await","break","callconv","catch","comptime","const","continue","defer","else","enum","errdefer","error","export","extern","fn","for","if","inline","linksection","noalias","noinline","nosuspend","opaque","or","orelse","packed","pub","resume","return","struct","suspend","switch","test","threadlocal","try","union","unreachable","usingnamespace","var","volatile","while"]
promote:primitive-type=["i8","u8","i16","u16","i32","u32","i64","u64","i128","u128","isize","usize","c_char","c_short","c_ushort","c_int","c_uint","c_long","c_ulong","c_longlong","c_ulonglong","c_longdouble","f16","f32","f64","f80","f128","bool","anyopaque","void","noreturn","type","anyerror","comptime_int","comptime_float"]
promote:value=["true","false","null","undefined"]

[[builtin-func]]
pattern=\\@[a-zA-Z_][a-zA-Z0-9_]*
color="cyan"

[[comment]]
pattern=\\//.*
color="dark-gray"
```