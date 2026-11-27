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

This installs `/Applications/Leaf.app` and the `leaf` command into `~/.local/bin`.

## Use

- Everything opens in Leaf's one window, also a note outside your folders (it shows with no row selected in the
  sidebar). The 20 files opened last stay in ⌘P.
- The `leaf` command opens notes and folders from the terminal and returns at once:

  ```sh
  leaf                    # bring Leaf to the front
  leaf notes/today.md     # open a note; a missing .md, .markdown or .adoc file is created first
  leaf ~/repo/docs/a.md b.md
  leaf ~/notes            # add the folder to the sidebar, or show it there
  leaf --help
  ```

  `LEAF_APP` points it at another build, and `LEAF_APP_ARGS` passes arguments when it starts Leaf, such as
  `LEAF_APP=build/Build/Products/Release/Leaf.app LEAF_APP_ARGS="-NotebookLibrary ~/test-notes" build/leaf a.md`.
- ⌘P goes to a file, recently opened first. ⌘K runs a command. ⌥⌘F searches inside notes.
- ⌘B toggles the sidebar, ⇧⌘B the outline. ⌘L makes a checklist, ⇧⌘L a link.
- The header is hidden; move the pointer to the top edge to show it, or run Show Header from ⌘K to keep it.

## License

GPL-3.0, the same as Notebook. See [LICENSE](LICENSE).
