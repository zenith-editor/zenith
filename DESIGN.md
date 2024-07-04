# Design

## Guidelines

These are some guidelines I try to follow when writing code:

* Follow the principle of locality of behavior: functions, variables and classes that have the same behavior should be placed closer together.
* Constructor functions should be named `create` if it has side-effects (such as allocating memory), `init` should be used otherwise.
* Method names should be verb (+ object). i.e. `getProperty()` instead of `property()`
* Always use blocks for if/while/for statements.

* Follow some rules about complexity Rob Pike wrote about in "Notes on Programming in C":

> * Rule 1.  You can't tell where a program is going to spend its time.  Bottlenecks occur in surprising places, so don't try to second guess and put in a speed hack until you've proven that's where the bottleneck is.
>
> * Rule 2.  Measure.  Don't tune for speed until you've measured, and even then don't unless one part of the code overwhelms the rest.
>
> * Rule 3.  Fancy algorithms are slow when n is small, and n is usually small.  Fancy algorithms have big constants. Until you know that n is frequently going to be big, don't get fancy.  (Even if n does get big, use Rule 2 first.)   For example, binary trees are always faster than splay trees for workaday problems.
>
> * Rule 4.  Fancy algorithms are buggier than simple ones, and they're much harder to implement.  Use simple algorithms as well as simple data structures.
>
>   The following data structures are a complete list for almost all practical programs:
>    * array
>    * linked list
>    * hash table
>    * binary tree
>
>   Of course, you must also be prepared to collect these into compound data structures.  For instance, a symbol table might be implemented as a hash table containing linked lists of arrays of characters.
>
> * Rule 5.  Data dominates.  If you've chosen the right data structures and organized things well, the algorithms will almost always be self-evident.  Data structures, not algorithms, are central to programming

* Prefix every "private" struct fields with "unprotected_"

## Pain points regarding Zig

* Passing structs by value does not guarantee that the struct will actually
be passed as a value, and not a reference. I wish it was explicit.
See [Footgun: hidden pass-by-reference (#5973)](https://github.com/ziglang/zig/issues/5973).
Until this gets resolved, **DO NOT PASS STRUCTS BY VALUE, USE POINTERS INSTEAD**

  * This appears to be an intentional design choice.
See [official documentation](https://ziglang.org/documentation/master/#Pass-by-value-Parameters).

  * Tigerbeetle solves this by always passing pointers.
See [tigerbeetle: Zig tracking issue (#1191)](https://github.com/tigerbeetle/tigerbeetle/issues/1191).

* Zig does not support error unions. There is no syntax for passing metadata along with errors. Zenith deals with this by having a custom Error generic union, which wraps the error type and payload, as well as the success value.

* Zig does not allow you to not use variables. You can't just prefix `_` to a variable to tell the compiler that the variable is not used.

* The `zig-cache` directory balloons to gigabytes after a while! Maybe link it to tmpfs and periodically clean up (the Makefile does this automatically).

### Other problems to investigate...

* ~~I'm not sure if it is safe to store allocators within other objects. The standard library does not do this, instead it always stores a reference to another allocator. It seems like moving allocators into another memory location may cause memory corruption (not detectable even with `.retain_metadata = true`), because internal data within the allocators (GeneralPurposeAllocator) links to other fields within itself, meaning if you were to copy the object to another location the pointers would be invalid? This is only a hypothesis I had when debugging a mysterious segfault. I checked and I did not do any double frees, or anything that would override the heap's metadata (`verbose_log` brought up nothing).~~ All objects now follow the allocator convention as set by Zig's standard library: allocators are never owned, it is up to the caller to create the allocator and pass it to the object.

