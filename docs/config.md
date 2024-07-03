# Config

Zenith looks up the main `zenith.conf` config file in the following directories:

  * **Linux, BSD:**
    1. `$XDG_CONFIG_HOME/zenith`
    2. `$HOME/.config/zenith`

An example configuration is provided in the *[sample-config](./sample-config)* directory.

Zenith uses a custom dialect of [TOML](https://toml.io/en/v1.0.0) to store configuration data. This dialect only supports pairs of keys and values, table headers in square brackets, and array headers in double square brackets. Only strings, integers (signed 64-bit), booleans and arrays are supported. In addition, the following extensions are supported:

  1. Zig-style multi-line strings:
  
  Example of the string `"a\nb"` represented under the new multi-line syntax:

```
key=\\a
    \\b
```

Paths are specified relative to the parent directory containing the `zenith.conf` file.

## Config keys

### General

  * `tab-size` (since *0.3.0*):
  
  (int) Sets the number of space characters inserted when pressing the tab key or adjusting the indentation level of a text block (in mark mode). The tab size is the number of space characters (ASCII code 32) to be inserted. Ignored if `use-tabs` is true.

  * `use-tabs` (since *0.3.0*):
  
  (bool) If true, tabs (ASCII code 9) will be used for indentation instead of spaces. Default is false.
  
  * `detect-tab-size` (since *0.3.3*):
  
  (bool) If true, the `use-tabs` and `tab-size` keys will be set based on the contents of the opened file. Default is false.
  
  * `use-native-clipboard` (since *0.3.0*):
  
  (bool) If true, the native system clipboard will be utilized instead of zenith's session-specific clipboard. In Linux environments, this requires `xclip` to be installed and the terminal to be ran in X11.

  * `show-line-numbers` (since *0.3.0*):
  
  (bool) Sets whether to show line numbers or not.
  
  * `wrap-text` (since *0.3.0*):
  
  (bool) Sets whether to wrap text or not.
  
  * `undo-memory-limit` (since *0.3.0*):
  
  (int) Specifies the maximum amount of memory (in bytes) allocated to the undo heap for managing text actions. When editing text, actions are recorded by allocating memory into the undo heap. If the editor attempts to record an action that causes the undo heap to exceed the limit specified by this configuration, the editor will display an error message. Default is *4 MiB*.

  * `escape-time` (since *0.3.0*):
  
  (int) Specifies the time delay (in milliseconds) for recognizing the escape key from stdin. In Xterm-compatible terminals, this configuration is used to resolve ambiguity in parsing escape sequences, where an escape sequence beginning with a standard printable character is indistinguishable from the an escape key press, and then a printable character being typed. It operates similarly to the 'escape-time' setting in tmux. Default is *20 ms*.
 
  * `large-file-limit` (since *0.3.2*):
  
  (int) Specifies the minimum number of bytes needed for a file to be classified as a large file. When a large file is opened, the following operations will be disabled:

    * Text wrapping
    * Syntax highlighting
    
    Defaults to *10 MiB*.
  
  * `update-mark-on-navigate` (since *0.3.2*):
  
  (bool) If true, then when navigating in text marking mode, the markers will automatically move without needing to press Enter. Defaults to *false*.

  * `use-file-opener` (since *0.3.2*):
  
  (array of strings) Specifies the command used for opening a file manager. If this setting exists, then when prompting for a file, Zenith will try to call the external file manager application and read the path of the selected file. The file manager should return the selected file by writing into stdout, and it should display its UI by writing into stderr. Defaults to nothing.

  *nnn* is the recommended file manager. In order to to use nnn as the file manager, set the key to the following:
  
```
use-file-opener = ["nnn", "-p", "-"]
```

  * `buffered-output` (since *0.3.6*):

  (bool) If true, then zenith will buffer terminal output before writing it into stdout. Enabling this option may or may not gain you any performance. Defaults to *false*.

  * `bg` (since *0.3.6*):

  (string or int) The default background color. Defaults to transparent.

  * `empty-bg` (since *0.3.6*):

  (string or int) The default background color for lines that are outside of text buffer. Defaults to transparent.

  * `color` (since *0.3.6*):

  (string or int) The default foreground color. Defaults to gray.

  * `special-char-color` (since *0.3.6*):

  (string or int) The default foreground color used for the following special characters: the character that is displayed when a line is wrapped. Defaults to cyan.

  * `line-number-color` (since *0.3.6*):

  (string or int) The default color used for line numbers. Defaults to cyan.

### Terminal feature flags

The following configuration keys control the use of specific terminal features by the editor. When the keys are true, the editor will use these features *if* the terminal supports them. Setting them to false means these features will not be used. The default setting for all configuration keys is *true*.

  * `force-bracketed-paste`: bracketed paste
  * `force-alt-screen-buf`: use the alternate screen buffer instead of the normal screen buffer.
  * `force-alt-scroll-mode`: if true and the alternate screen buffer is used, then scrolling will be enabled
  * `force-mouse-tracking`: enables mouse tracking (required for detecting clicks and scrolls)

### Specifying colors

For keys requiring colors as value, you may either specify colors as integers (for escape sequence compatible colors), or strings. Under string form, the following values are accepted:

  * `black`
  * `dark-red`
  * `dark-green`
  * `dark-yellow`
  * `dark-blue`
  * `dark-purple`
  * `dark-cyan`
  * `gray`
  * `dark-gray`
  * `red`
  * `green`
  * `yellow`
  * `blue`
  * `purple`
  * `cyan`
  * `white`

## Syntax highlighting config

Syntax highlighting is defined by external configuration files. These files may contain collections of patterns that the editor uses to recognize various syntax elements. Zenith reads every highlighting configuration declared in `zenith.conf`. Here is an example of a *highlighting declaration*:

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

## Config keys for highlighting declarations

  * `path` (since *0.3.0*):
    
    (string) Path of the highlighting file, relative to the parent config directory.
    
  * `extension` (since *0.3.0*):
  
    (string, or array of strings) Specifies for which file extension that this highlighting schema should be applied to. Each extension must begin with a '.'.

## Config keys for highlighting file

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

  * `inherit:...` (since *0.3.6*):

  (string) The name of the token in the main config file which this token inherits its attributes from. The inheriting token will only inherit the color and text decoration of the parent token.

## Example

See *[sample-config/highlight](./sample-config/highlight)* for example highlight config files.
