<p align="center">
  <img src="assets/icon.png" width="160" alt="Diffactly app icon">
</p>

<h1 align="center">Diffactly</h1>

<p align="center"><b>A free, fast, native macOS diff checker.</b></p>

A fast, native and free macOS text comparison tool with real-time diff highlighting and a minimal interface.

## Screenshots

**Review a code change** – side-by-side, with word- and character-level highlights inside edited lines.

<img src="assets/screenshots/split-view-dark.png" alt="Diffactly split view comparing two versions of a TypeScript file in dark mode">

**Check a config change before you ship it** – a unified view in light mode, like `git diff` but readable.

<img src="assets/screenshots/unified-view-light.png" alt="Diffactly unified view showing a docker-compose.yml upgrade in light mode">

**Compare document revisions** – with the optional Insights panel: similarity, line composition, a clickable change map and word shifts.

<img src="assets/screenshots/insights-light.png" alt="Diffactly split view of release notes with the Insights panel open">

## Features

- **Accurate diffs**: lines are aligned with a weighted algorithm that favours long, meaningful matches (re-indented lines still line up), and edited lines are paired by similarity so you see *what* changed inside them
- **Three precisions**: Smart (word diff, refined to single letters for typo-sized edits), Word, and Character
- **Moved-block detection**, including blocks that were moved *and* edited, with the edits highlighted
- **Edit, Split and Unified views**: live highlighting while you type, or an aligned read-only comparison with collapsible unchanged lines and next/previous change navigation (⌃⌘↓ / ⌃⌘↑)
- **Ignore options**: whitespace, case, quote style, dash style and custom strings
- **Transforms**: lowercase, sort lines, join lines, trim whitespace
- **Word counts**: live word totals for both texts (with the net change) in the status bar, plus the words and characters in your selection while editing
- **Insights (optional)**: toggle the chart button (⌥⌘I) for similarity, line composition, a clickable change map and word-frequency shifts
- **Open files** with ⌘O / ⇧⌘O, drag-and-drop, Finder's *Open With*, or `diffactly --gui`
- **Clear** a side with its ⓧ button or ⌘K (the focused side), or both with ⇧⌘K
- **Auto, Dark and Light modes**
- **Native**: SwiftUI + AppKit, no dependencies

## ⌨️ Command line

The same engine ships as a CLI (`DiffactlyKit/`, Swift package):

```sh
scripts/install-cli.sh            # builds and installs `diffactly`

diffactly old.txt new.txt             # coloured unified diff with inline highlights
diffactly -f split -l word a.md b.md  # side-by-side in the terminal
diffactly -f inline draft1 draft2     # [-removed-]{+added+} word diff
diffactly -s -g before.json after.json   # stats plus graphs (composition, change map, word shifts)
diffactly -f json a b                 # machine-readable result
diffactly -f patch a b | patch a      # valid unified patch
diffactly dirA dirB                   # compare folders recursively
diffactly --gui a b                   # open the comparison in Diffactly.app
git config --global diff.external "diffactly git"   # use Diffactly for `git diff`
```

Exit status follows `diff`: `0` same, `1` different, `2` trouble. Run `diffactly --help` for every option.

## 💻 Get it

Download the .app from the [releases](https://github.com/QuantumKuba/Diffactly/releases) page, or build it yourself by opening `Diffactly.xcodeproj` in Xcode.

Found a bug? Please [report it](https://github.com/QuantumKuba/Diffactly/issues).

## 🤝 Contributing

We welcome contributions! Here's how you can help:

1. Clone the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

Please ensure your PR:

- Follows the existing code style
- Includes appropriate tests
- Updates documentation as needed

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Links

- Repository: [QuantumKuba/Diffactly](https://github.com/QuantumKuba/Diffactly)
- Report issues: [GitHub Issues](https://github.com/QuantumKuba/Diffactly/issues)
