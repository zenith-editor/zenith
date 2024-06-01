# Patterns

Zenith uses a custom pattern matching language, which is  **not** guaranteed to be compatible with standard regular expresisons. Patterns work on Unicode code points. Here is a quick reference table for supported operators:

| **Pattern**   | **Meaning**                                                  |
| ------------- | ------------------------------------------------------------ |
| `.`           | matches any character
| `a`           | matches the character `a`
| `[a-zA-Z]`    | matches the range `a` to `z`, `A` to `Z`
| `[^a-zA-Z]`   | matches characters not in range `a` to `z`, `A` to `Z`
| `+`           | greedy matches 1 or more character or group
| `*`           | greedy matches 0 or more character or group
| `-`           | lazily matches 0 or more character or group
| `?`           | greedy matches optional character or group
| `|`           | alternate
| `(az)`        | matches the group with the characters `az`
| `^`           | anchor start
| `$`           | anchor end

Escape characters:

| **Character** | **Code point**                  |
| ------------- | ------------------------------- |
| `\b`          | `0x08`
| `\f`          | `0x0C`
| `\n`          | `0x0A` (line feed, or new line)
| `\r`          | `0x0D` (carriage return)
| `\t`          | `0x09` (tab)