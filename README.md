# DBGram

A fast native macOS viewer for [DBML](https://dbml.dbdiagram.io/docs/) schemas (the dbdiagram.io language).

- **Native and fast.** Each table is drawn once into a cached Core Animation layer, so pan and zoom only move GPU textures. Parsing plus layout of 1,500 tables (32k lines) takes about 200 ms.
- **Live reload.** Edit the `.dbml` file in any editor and the diagram updates on save. Positions you dragged are kept.
- **Auto layout.** Tables that are referenced sit on the left and the tables pointing at them sit on the right. Each `TableGroup` is laid out as its own cluster.
- `headercolor`, TableGroup `color`, notes (hover a row or a table header), composite keys, enums, `TablePartial`, multi-line strings.

## Build & run

```sh
scripts/build-app.sh            # -> build/DBGram.app
scripts/build-app.sh --install  # also copies to /Applications and registers .dbml
open build/DBGram.app --args examples/core.dbml
```

Development: `swift run DBGram examples/core.dbml`, `swift test`.

Export without UI: `DBGram --render in.dbml out.png [--dark] [--scale 2]`.

## Controls

| Action | How |
| --- | --- |
| Pan | two-finger scroll, or drag the background |
| Zoom | pinch, ⌘/ctrl + scroll, mouse wheel, ⌘= / ⌘- |
| Fit / 100% | ⌘0 or `F` / ⌘1 |
| Find table or column | ⌘F, then Enter |
| Focus a table | double-click it, or click it in the sidebar |
| Move a table | drag it (saved per file in `~/Library/Application Support/DBGram`) |
| Re-arrange everything | ⌘⇧L |
| Paste DBML from clipboard | ⌘⇧V |
| Export PNG | ⌘⇧E |

## Layout

- `Sources/DBMLKit`: DBML lexer and parser (tolerant: errors are listed with line numbers and the rest still renders), model, layered layout.
- `Sources/DBGram`: AppKit canvas (`DiagramCanvas`), table drawing, SwiftUI window shell.
- `scripts/gen-stress.py`: generates big synthetic schemas for performance testing.
