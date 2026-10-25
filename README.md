# YABUB4JS - Yet Another Blissfully Unaware Bundler For JavaScript

YABUB4JS is a small, almost dependency-free JavaScript bundler written in
Bash.

[[ GitHub Repository ]](https://github.com/works-as-evolving/yabub4js)

Unlike most JavaScript bundlers, YABUB4JS does not transpile, optimize,
minify, obfuscate, isolate, or hide implementation details. Instead, it
**feeds** multiple source files into a single readable and debuggable
distribution file while preserving the original source structure as much as
possible.

Generated files are intended to remain source code. Manual fixes can be
applied directly to the distribution file and easily backported to the
original modules.

## Features

- Single-file distribution output
- Readable and debuggable generated code
- No source maps required
- Supports namespace imports

  ```js
  import * as ns from './module.mjs';
  ```

- Supports named imports

  ```js
  import { a, b as c } from './module.mjs';
  ```

- Build-time placeholders

  ```js
  /** @version {:VERSION:} */
  /** @integrity {:SHA1SUM:} */
  ```

- Import directives via URL *fragments*

  ```js
  import { nop, IIFE } from '../lib/syntax.mjs#early';
  ```

## Usage

```sh
curl -sf https://works-as-evolving.github.io/yabub4js/bin/yabub4js.sh \
  | bash -s <srcdir> <entrypoint> <outfile>
```

Example:

```sh
curl -sf https://works-as-evolving.github.io/yabub4js/bin/yabub4js.sh \
  | bash -s ./src svc/dt42-svc.mjs ./dist/dt42-svc.mjs
```

## Philosophy

YABUB4JS is intentionally **not** a JavaScript parser.
It understands a small subset of ECMAScript module syntax and relies on a
few practical assumptions to keep the implementation simple, portable, and
easy to understand.

If you need tree-shaking, transpilation hot-module reloading, source-maps,
or a complete ECMAScript parser, there are plenty of excellent tools
available already.

YABUB4JS is blissfully unaware of all that.
