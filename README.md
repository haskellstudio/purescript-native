**Pure11** is an experimental C++11 compiler/backend for [PureScript](https://github.com/purescript/purescript). It attempts to generate "sane" and performant C++11 code (instead of JavaScript), in the spirit of PureScript.

#### Status:

* Alpha (0.1) — very early, contributions welcome!

#### Performance

* No runtime system (beyond the standard C++11 runtime library)
* Uses template metaprogramming extensively to transpose the original source type system — minimal performance cost when running
* Uses native C++11 reference counting (`std::shared_ptr`) for relatively lightweight automatic memory management
* Uses PureScript's normal tail call optimizations for generated C++11 code

#### Differences from PureScript:

* Inline code (foreign imports) are C++11 instead of JavaScript
* Built in `Int` (C++ `int`), `Integer` (C++ `long long`), Char (C++ `char`) primitive types
* Compiler is `pcc` instead of `psc` or `psc-make`, and only supports `make` mode
  - Generates a simple CMake file for easy experimentation
* No Pure11-specific REPL right now

#### Other notes:

* Built-in lists use a custom, STL-like `shared_list` (immutable list) type
  - Built-in conversions to `std::vector`
  - Built-in conversions to `std::string` for `Char` list
* `String` type corresponds to `std::string` (at least for now)
* `Number` is C++ `double` type, with `Double` and `Float` aliases

#### TO-DO:

* Proper break-out of pure11 generation — just a hacked fork right now
* Get automated builds/tests up and running (equivalents of PureScript)
* Support for `type` in generator (e.g. generate C++11 `using`)
* Introduce `Char` literals (make similar to Haskell's), possibly try to push upstream to PureScript
* Optimized `newtype` (some work already done, but disabled for now)
* ST monad (in Prelude)
* "Magic do" (similar work already done in inliner and TCO code)
* Unicode (UTF-8) support for `String` (Borrow code from my Idris backend)
* Lots of testing and code cleanup!

#### Future ideas:

* Instance names aren't used in generated C++11 code - possibly make them optional
* Compiler options for memory management
* `BigInt` via GNU GMP, possibly replacing current implementation of `Integer`
* Stricter exports in C++ code
* Use C++ operator overloading where supported

### Requirements

* Everything you need to build [PureScript](https://github.com/purescript/purescript)
* A C++11-capable toolchain, e.g. recent versions of clang, gcc
* Installed CMake is helpful (for the provided quickstart CMake file generated), though not required. You should be able to use your favorite C++ build system, tools, debuggers, etc., for the generated code.
