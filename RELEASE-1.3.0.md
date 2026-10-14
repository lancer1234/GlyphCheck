# GlyphCheck 1.3.0

- Audit Glyphs glyph-name text lists, including unencoded names and variants. Inspect actual glyphs, record notes, and export HTML/CSV/JSON coverage reports. Unknown mappings remain unresolved.
- Choose external or installed donor fonts, preview supplements/replacements, and accept each repair before exporting. Original files remain unchanged.
- Read complete articles with synchronized scroll anchors and selected text across both previews.
- Task-based entry points, reusable character lists, problem-first review, possible-variant judgments, and self-contained visual reports.

## Requirements and limits

Apple silicon · macOS 14+. Download the ZIP, extract and open **字形檢查器.app**. This build is ad-hoc signed, not notarized; it is not an Apple-verified download.

Cross-font output supports static, non-color TrueType targets. Static TrueType/CFF outlines can supply donors. Source widths are scaled to target units; style matching and shaping-table repair are not automatic. Glyphs support is for glyph-name lists, not `.glyphs` design files. Presence is not proof of semantic correctness.

Existing progress files remain readable. Old repair suggestions require explicit acceptance. No private fonts or third-party character lists are bundled.

## License

Free to use, modify and share, including commercial work. Original and modified versions may not be sold without written permission. Retain attribution and license, mark modifications, and keep the no-resale terms when sharing modifications. Source available, not open source. Previous MIT grants and third-party font/dependency licenses are unaffected. See LICENSE.

[Download](https://github.com/lancer1234/GlyphCheck/releases/latest) · [Usage](README.md) · [Feedback](https://github.com/lancer1234/GlyphCheck/issues)
