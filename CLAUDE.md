## Code style

Formatting uses each tool's standard defaults, the same across all `dividedby` repos. Don't add style options or format by hand. Files format on edit through the post-edit hook. CI checks it in `.github/workflows/format.yml`.

- **JS, TS, HTML, CSS, JSON, Markdown, YAML:** Prettier defaults. Run `pnpm format`, or `pnpm format:check` to check.
- **Shell:** `shfmt` with 2-space indentation, per Google's Shell Style Guide. Set in `.editorconfig`.
- **Swift:** `swift-format` defaults, with the 4-space indentation Xcode uses. Set in `.swift-format`.
