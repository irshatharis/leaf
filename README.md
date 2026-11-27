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

## License

GPL-3.0, the same as Notebook. See [LICENSE](LICENSE).
