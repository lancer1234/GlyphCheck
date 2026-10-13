# GlyphCheck 1.2.0

A local-first native macOS assistant for human glyph review and legacy-font restoration, by [MAKOTO LAB](https://makotolab.tw/).

## New in 1.2 / 本次更新

- Traditional Chinese, Simplified Chinese and English UI in native Settings (⌘,).
- English / Basic Latin, Latin letters & accents, and numbers & punctuation scopes. Non-CJK references show Unicode character names.
- Preflight flags for blank outlines, shared outlines and glyph-name / Unicode differences. Flags prioritize review; they are not automatic semantic judgments.
- Workbench with mapping-chain / swap inspection, editable text proofs and original / repaired comparisons.
- Portable `.glyphreview` tasks with original SHA-256 + face matching, reviewer names, merge history and conflict reconciliation. Fonts are not included.
- Preflight, population-missing and mapping-trace reports. Disputed answers and reference doubts cannot supply repair donors.
- Native About panel with MAKOTO LAB, GitHub and sponsor links; blue glyph-magnifier icon and copyright footer.
- Existing 1.0 / 1.1 progress files remain readable. Old sessions without preflight metadata do not claim to have been rescanned.

繁中／簡中／英文介面移至「設定」。新增拉丁字元範圍、預掃描、對應追查、詞句檢查、修復前後對照與多人分工核對。保留 Enter 快速判定、隨機抽樣、中途報告與原檔保護。

## Download / 安裝

Download **GlyphCheck-1.2.0-macOS-arm64.zip**, extract and open 字形檢查器.app. See SHA256SUMS-1.2.0.txt for the archive checksum.

**Apple silicon Mac, macOS 14+.** Python and fontTools are bundled; no separate installation is required. This build is ad-hoc signed, **not Apple notarized**. Review the source and checksum before deciding whether to allow it; do not disable Gatekeeper.

## Boundaries / 限制

Fonts stay local; original files are not overwritten and fonts are not automatically installed. Repair only reassigns cmap entries from human-confirmed donors: no OCR guesses, no new glyph drawing, no kerning / GSUB / GPOS repair. Text proofing is visual, not a comprehensive automatic shaping audit. Color / bitmap fonts and variable-axis-specific review are not supported. Reports retain Chinese filenames and some Chinese diagnostics.

Please test with fonts you have permission to modify. Font licenses remain applicable; the app's MIT license does not grant rights to imported fonts.

Feedback: [GitHub Issues](https://github.com/lancer1234/GlyphCheck/issues) · [MAKOTO LAB](https://makotolab.tw/) · [Buy Me a Coffee](https://buymeacoffee.com/MakotoLab)
