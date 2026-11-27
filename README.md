# Leaf

A fast, minimal Markdown notes app for the Mac that works on a plain folder of `.md` files.

Leaf is a fork of [Notebook](https://github.com/lukaskaibel/notebook) by Lukas Kaibel. It keeps Notebook's editor,
where Markdown renders as you type and its marks show only around the cursor, and removes most of the rest.

## Install

Needs macOS 27 and Xcode 27.

```sh
git clone git@github.com:irshatharis/leaf.git
cd leaf
Tools/build.sh
```

This installs `/Applications/Leaf.app` and links the `leaf` command into `~/.local/bin`.

## Use

- `leaf path/to/note.md` opens a note in the main window (in a window of its own when it is outside your folders).
  A missing `.md` path is created first. `leaf some/folder` adds a folder to the sidebar.
- ⌘P goes to a file, recently opened first. ⌘K runs a command. ⌥⌘F searches inside notes.
- ⌘B toggles the sidebar, ⇧⌘B the outline. ⌘L makes a checklist, ⇧⌘L a link.
- The header is hidden; move the pointer to the top edge to show it, or run Show Header from ⌘K to keep it.

## License

GPL-3.0, the same as Notebook. See [LICENSE](LICENSE).
