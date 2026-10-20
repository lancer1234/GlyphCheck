# GlyphCheck — 字形檢查器

由 [MAKOTO LAB](https://makotolab.tw/) 開發的 macOS 原生字形核對工具，協助檢查缺字、誤植與老字檔的錯誤對應，逐字驗收後再匯出修復結果。

A native Mac app for reviewing glyphs, investigating incorrect character mappings and restoring older fonts. Fonts and reviews stay on your Mac.

[![Download](assets/button-download.svg)](https://github.com/lancer1234/GlyphCheck/releases/latest)
[![Source](assets/button-github.svg)](https://github.com/lancer1234/GlyphCheck)
[![MAKOTO LAB](assets/button-studio.svg)](https://makotolab.tw/)
[![Support](assets/button-coffee.svg)](https://buymeacoffee.com/MakotoLab)

**1.6.0 · Apple silicon · macOS 14+** · [本次更新](RELEASE.md)

## 開始使用

1. 下載 ZIP、解壓並開啟「字形檢查器.app」。目前為 ad-hoc 簽署，尚未公證。
2. 首頁選「開始檢查字檔」或「檢查一段文字」，匯入 TTF／OTF／TTC／OTC。
3. 按「開始逐字核對」：字形正確就按 **Enter**；看到其他字，輸入那個字再按 Enter，程式會接著追查該字。拿不準時保留待確認，不用猜。
4. 隨時離開，下次從「我的進度」繼續。範圍、繁簡和抽樣在「進階選項」；「？」提供簡短指南。

首次啟動依系統偏好選擇繁體中文、簡體中文或英文；之後記住設定，不受匯入專案影響。

## 進度與分享

- 進度自動保存在 App 專用資料區，更新程式不會刪除。可在「我的進度」續接與命名；保存時保留上一份備份。
- 「進度選項 → 匯出進度…／分享進度…」產生可攜式 `.glyphcheck` 文件包。匯入後由 App 管理獨立副本，不依賴原電腦路徑。
- 預設不附字檔；接收者需提供相同原檔，程式會核對 SHA-256。有權分享字檔時才勾選包含原檔。**文章與註記可能包含私人內容，分享前請確認。**

舊進度仍可匯入；原字檔遺失時需重新指定。內部資料位於 `~/Library/Application Support/字形檢查器/Sessions/`，不存放在 `.app` 安裝包內。

## 工具箱

匯入字檔後按「開啟工具箱」，或在逐字核對時使用「工作台」：

- **預掃描：** 找出缺字、空白、重複輪廓與可疑名稱。
- **字集驗收：** 匯入 Glyphs 字形名稱文字清單，檢查涵蓋範圍並執行本機 OCR 初篩。
- **對應追查：** 追查人工回報的誤植與互換字碼。
- **詞句檢查：** 比對文章排版，左右捲動及反白同步。
- **修復對照：** 使用原檔內已確認字形，或從其他字檔／本機字體補字與替換；逐項驗收後輸出獨立修正版。
- **多人核對：** 匯出任務、合併答案並保留衝突。HTML／CSV／JSON 報告可在中途匯出。

<img src="assets/screenshots/review.png" alt="Side-by-side glyph review with a system reference" width="760">

<details>
<summary>更多介面截圖</summary>

<img src="assets/screenshots/charset-audit.png" alt="Glyph-name coverage audit" width="760">
<img src="assets/screenshots/text-proof.png" alt="Synchronized text comparison" width="760">

截圖為功能示意；示範字檔可能刻意使用錯誤輪廓，不代表第三方字體或字集有問題。
</details>

## 重要限制

- OCR 分為辨識相符、疑似誤植、無法判定；相符不代表已人工確認。疑似誤植需要多次辨識及輪廓佐證，仍可能誤判或漏判；舊 OCR 結果需重新初篩。
- Glyphs 支援的是**字形名稱清單**，不是 `.glyphs`／`.glyphspackage` 設計檔編輯。無可靠字碼對應的變體保留待確認，不內建第三方字集。
- 修復限靜態、非彩色 TrueType 目標；來源輪廓可為 TrueType／CFF。不自動畫缺字、調整風格或修復塑形表；連字、垂直替換與變體需另行驗證。
- 原字檔不覆寫、不自動安裝。字形核對可離線使用；只有「檢查更新」會查詢 GitHub 正式 Release，不自動下載或安裝新版。

## 建置與測試

需要 Apple silicon Mac 與 Swift 開發工具。建置腳本會下載並校驗固定版本的 Python runtime、安裝固定版本的 fontTools。

```sh
git clone https://github.com/lancer1234/GlyphCheck.git
cd GlyphCheck
zsh build.sh
open dist/字形檢查器.app
```

字檔及 Swift 回歸測試見 [Tests workflow](.github/workflows/tests.yml)。公開測試使用生成字檔，不包含私人字體。

<a id="acknowledgments"></a>

## 致謝與回饋

感謝 [justfont](https://justfont.com/) 國榕的流程回饋與 [jf7000](https://justfont.com/jf7000) 字集；感謝 [LXGW／霞鶩文楷](https://github.com/lxgw/LxgwWenKai)、[繁體版本](https://github.com/lxgw/LxgwWenKaiTC) 貢獻者與上游 [FONTWORKS Klee One](https://github.com/fontworks-fonts/Klee) 作者。字體與字集保留原授權、不隨 App 散布，致謝不代表合作或背書。

[![Feedback](assets/button-feedback.svg)](https://github.com/lancer1234/GlyphCheck/issues)

歡迎回報使用情境與需求；請勿上傳未獲分享授權的字檔或含私人資料的進度。

## 授權

[GlyphCheck Free Use and Modification License](LICENSE)：可免費使用、修改與分享，包含商業工作用途；未經書面許可，不得販售原版或修改版程式。保留署名、授權與禁售條款，標示修改。原始碼公開，**非開源授權**。

Free to use, modify and share; no resale of original or modified software without written permission. Outputs and user fonts retain their own rights. Earlier MIT grants remain valid; see [legacy MIT license](LICENSE-MIT-LEGACY.txt) and [third-party notices](THIRD_PARTY_NOTICES.md).
