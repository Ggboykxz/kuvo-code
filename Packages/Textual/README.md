# Textual

The Markdown renderer for replies, in Kuvo Code and Kuvo Code for iPhone.

**This is a copy of [Textual](https://github.com/gonzalezreal/textual) by Guille Gonzalez (MIT),
at upstream 0.5.0 (`01b5187`), with changes of Kuvo Code's own.** Its tests, examples and scripts
aren't copied.

## What's different from upstream

Upstream lays a text out over several passes: `StructuredText` parses its markup in an
`onChange(initial:)` after it's first drawn, and so do the inline styles and each fragment's
`Text`. A reply was laid out empty first, then at its size, so in a lazy stack its height changed a
frame after it appeared, and the conversation jumped while you scrolled up into it. Here:

- **One pass.** `StructuredText` parses, `WithInlineStyle` styles and `TextFragment` builds its
  `Text` as the view is drawn, each kept and made again only when what it's made from changes.
- **Less per fragment.** A fragment watches its container's size only when it has attachments,
  overlays its attachments only when it has some, takes link taps only when it has links, and
  lays out a view for the selection only while something is selected.
- **The code highlighter starts off the main thread.** Making it (JavaScriptCore with Prism)
  took a quarter of a second, on the first code block's way to the screen.

## Updating

Compare upstream's changes since `01b5187` with this copy, and port them by hand, keeping the
changes above.
