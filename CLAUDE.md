# Leaf

A personal fork of [Notebook](https://github.com/lukaskaibel/notebook) by Lukas Kaibel, trimmed for speed, low memory
and a minimal window. Mac only for now. GPL-3.0, like upstream.

## Priorities

Performance, low memory (the app stays open all day), less UI, less code. When in doubt, delete.

## Build and check

- `Tools/build.sh` builds Release and installs `/Applications/Leaf.app` plus the `leaf` CLI. `--no-install` only builds.
- `Tools/measure.sh build/Build/Products/Release/Leaf.app` reports time to first window, footprint and idle CPU on
  `~/vaults/irsh-world`. Run it before and after any change that could cost memory or launch time.
- Xcode 27 is required. Scripts set `DEVELOPER_DIR` to `/Applications/Xcode.app` themselves.

## Keeping up with upstream

`upstream` is lukaskaibel/notebook. Internal names (`NotebookKit`, `Notebook.xcodeproj`, type names) stay as they are
so upstream merges stay small. Only user-visible text says Leaf.
