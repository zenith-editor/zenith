# Design

## Guidelines

* Follow the principle of locality: functions, variables and classes that are related
should be closer together in the source.

## Pain points relating to Zig

* Passing structs by value does not guarantee that the struct will actually
be passed as a value, and not a reference. I wish it was explicit.
See [Footgun: hidden pass-by-reference (#5973)](https://github.com/ziglang/zig/issues/5973).
Until this gets resolved, **DO NOT PASS STRUCTS BY VALUE, USE POINTERS INSTEAD**

  * This appears to be an intentional design choice.
See [official documentation](https://ziglang.org/documentation/master/#Pass-by-value-Parameters).

  * Tigerbeetle solves this by always passing pointers.
See [tigerbeetle: Zig tracking issue (#1191)](https://github.com/tigerbeetle/tigerbeetle/issues/1191).

* Zig does not support error unions. There is no syntax for passing metadata along with
errors. Zenith deals with this by having a custom Error generic union,
which wraps the error type and payload, as well as the success value.

* Zig does not allow you to not use variables. You can't just prefix `_` to a variable
to tell the compiler that the variable is not used.

* The `zig-cache` directory is way too huge! Maybe link it to tmpfs and periodically
clean up (the Makefile does this automatically).