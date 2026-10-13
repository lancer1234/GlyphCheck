# GlyphCheck — 字形檢查器

A minimal native macOS tool for **human review of font glyphs and incorrect character mappings**, built with SwiftUI, AppKit and CoreText by [MAKOTO LAB](https://makotolab.tw/).

[Download](https://github.com/lancer1234/GlyphCheck/releases) · [MAKOTO LAB](https://makotolab.tw/) · [Buy Me a Coffee ☕](https://buymeacoffee.com/MakotoLab)

## 為什麼做這個工具？

「字檔有這個字碼」不代表「它畫的就是這個字」。老字檔可能缺字、留白，也可能把完整字形對到錯的字碼。自動輪廓檢查或 OCR 不能取代人工確認。

GlyphCheck 讓你逐字看、逐字判定；遇到誤植會接著追查你看到的字，最後產出可以交給 AI 或字體修復者使用的清單。

## 功能

- 匯入一或兩個 **TTF / OTF / TTC / OTC** 字檔並排檢查；集合字檔可選擇字面。
- 完整檢查或隨機抽樣，抽樣數量自行輸入；搭配系統參考字形與拼音。
- 開始前可選繁體／簡體介面，並獨立選擇繁體／簡體／不限制的字元篩選。
- 「問題字」清單可點選誤植、缺字、待確認或參考存疑字，直接複查。
- **直接按 Enter** 確認正確並進入下一題。輸入一個字後按 Enter，回報看到的字並追查該字。
- 每個字檔各自記錄判定，支援無法辨認、上一題、指定字複查。
- 自動保存，可分多次檢查。
- 隨時匯出目前修正建議、缺字、已修正、未修正、待確認、未抽樣、人工判定與參考存疑清單（JSON + UTF-8 CSV），不用跑完整份字檔。
- 嘗試使用**人工確認的原字形來源**修復字碼表；原檔不覆寫，新字檔使用獨立名稱。
- 本機處理，不上傳字檔、不連網分析，也不自動安裝字體。

## 安裝

適用 **Apple silicon Mac，macOS 14 或以上**。Intel Mac 尚未提供預編譯版本。

1. 到 [Releases](https://github.com/lancer1234/GlyphCheck/releases) 下載 ZIP 並解壓縮。
2. 將「字形檢查器.app」放進「應用程式」或桌面，再開啟。
3. 發布版本只有本機簽署，**尚未經 Apple 公證**。若 macOS 阻擋，請先核對下載來源、公開程式碼與 Release 的 SHA-256，自行決定是否允許開啟；不要關閉 Gatekeeper 或移除安全檢查。

App 已包含 Python 與 fontTools，使用者不需要另外安裝。

## 使用方式

### 1. 匯入與範圍

按「匯入字檔」或拖入字檔。可以加入第二份檔案，例如 A、B 版。

| 範圍 | 內容 |
| --- | --- |
| 字檔所有字元 | 匯入字檔字碼的聯集；排除空白與控制字元 |
| 漢字基本區 | U+4E00–U+9FFF |
| 漢字基本＋擴展 A | 基本區 + U+3400–U+4DBF |
| 自訂文字 | 貼上指定文字，自動去除重複字 |

「所有字元」不是整個 Unicode。要尋找特定範圍的缺字，請選相應漢字範圍或貼入自己的字表。

介面語言與字元篩選是兩個獨立設定。字元篩選保留共用字，使用 macOS 的單字繁簡轉換判斷；古字、語義歧義及一對多轉換仍可能需要人工辨認。篩選只改變出題範圍，不會改寫字檔或把繁體字碼轉成簡體字碼。

選「隨機抽樣」後，輸入正整數。App 會從至少一個匯入字檔有字形的候選字元中，不重複抽取指定數量；超過可抽樣數量會提示，不會悄悄改成另一個數量。誤植追查與指定複查可能追加字元，與最初抽樣分開記錄。抽樣結果不代表整份字檔已確認。

### 2. 快速判定

- **正確：直接按 Enter。** 比對兩個字檔時，沒有另作標註的字檔會一起確認正確。
- **是另一個字：** 在該字檔的「我看到的字是…」輸入一個字，再按 Enter。
- **中文輸入法選字：** Enter 先確認輸入法選字，組字完成後再按一次 Enter 提交。
- **看不清：** 用「無法辨認」或「暫時不確定」，不用猜。
- **參考也存疑：** 切換參考字體，或按「參考字也存疑」。
- 「上一題」撤回本次開啟以來的判定；「指定字複查」可以重看任意字。
- 按「問題字」開啟清單，可按類型篩選並點字複查。缺字自動列出，不用手動打答案。

Enter 會保留已標記的「誤植」或「無法辨認」，不會把它們直接改成正確。連續按下可逐題確認；按住 Enter 不會大量跳題，避免誤判。

### 3. 追查錯誤對應

例如題目是「常」，字檔卻畫成「帽」：輸入「帽」後，下一題優先檢查「帽」。若「帽」又畫成「幅」，就繼續追查「幅」。兩個字檔各自記錄。

系統參考可以使用 macOS 備援字體；**待檢查字形直接讀取選定字檔的輪廓，不使用備援字體掩蓋缺字**。

### 4. 保存與續接

每次提交自動保存。重新開啟後按「繼續上次檢查」。右上角選單可開啟進度、保存副本或顯示工作階段資料夾。

預設資料位置：`~/Library/Application Support/字形檢查器/Sessions/`。

`.glyphcheck` 引用工作階段資料夾的原檔副本。跨電腦搬移需要保留整個資料夾，並調整進度檔中的本機路徑；單獨的進度檔不是可攜式專案。CSV / JSON 報告可獨立交給 AI。

### 5. 匯出與修正

「匯出」可選只產出報告，或「嘗試修正並匯出」。完成一輪後仍可繼續待確認字。

**不用等待全部完成。** 檢查途中就能按「匯出目前建議與報告」，問題字清單中也有匯出按鈕。已明確標記但尚未進下一題的判定會一起保存；只輸入而尚未回報或提交的文字不當成已確認答案。

報告保留未確認與未抽樣字元，不會將它們認定為正確。抽樣外追加的追查字、原始抽樣數與完整候選範圍會分別記錄。

輸出包含：

- `報告摘要.txt`、`檢查報告.json`：範圍、統計、原檔 SHA-256、逐字判定、修正來源及限制。
- 各字檔的 `缺字.csv`、`修正建議.csv`、`已修正.csv`、`未修正.csv`、`待確認.csv`、`未抽樣.csv`、`人工判定.csv`、`參考存疑.csv`。
- `檢查進度.glyphcheck`。
- 有安全修正來源時，另產生 `*-repaired.ttf` 或 `*-repaired.otf`。

相同目標有不同候選字形時保留為未修正；沒有人工確認來源也不猜改。缺字表列出原始缺字，若已找回字形，狀態會標記「已由確認來源恢復」。

## 限制

- 這不是「全字庫絕對正確」驗證器。錯誤人工標註仍可能造成錯修。
- 拼音是系統單字轉寫，不能保證多音字、方言或罕見字完整；非漢字可能沒有拼音。
- 缺字以選定範圍為準；空白與控制字元不出題，未檢查字保留為待確認。
- 抽樣的缺字報告只涵蓋原始樣本與額外追查／複查；未抽樣的字另外列出，不會被宣告為完整缺字調查。
- 自動修正僅重編 Unicode 字碼表（cmap），不畫缺字、不猜補字，不修 GSUB/GPOS、連字、垂直字形、變體選擇符或複雜排版。
- 適合一般輪廓字體；彩色／點陣字體、特殊舊編碼及部分異常檔案可能不支援。變動字體使用預設字面，不提供軸值檢查。
- 可復原部分異常 format-4 字碼表，並轉換 Windows Big5，但不保證原始字義正確。
- 原字體授權仍適用。請先取得修改與分享權利；本工具的 MIT 授權不涵蓋匯入字檔。

## 從原始碼建置

需要 Apple silicon Mac、Xcode（或含 Swift 的開發工具）、curl，以及首次建置的網路連線。

```sh
git clone https://github.com/lancer1234/GlyphCheck.git
cd GlyphCheck
zsh build.sh
open dist/字形檢查器.app
```

腳本下載固定版本的官方 `python-build-standalone`，驗證 SHA-256，並從 PyPI 安裝固定版本的 fontTools。只有建置過程需要下載，完成的 App 離線運作。也可以自行提供可信的獨立 Python 3.12 runtime：

```sh
PYTHON_RUNTIME=/path/to/python APP_OUTPUT=/path/to/字形檢查器.app zsh build.sh
```

測試：

```sh
python3 -m venv .venv
.venv/bin/pip install fonttools==4.66.1
.venv/bin/python test_backend.py
swiftc -swift-version 5 -D TESTING -parse-as-library GlyphCheck.swift test_engine.swift \
  -o test-engine -framework SwiftUI -framework AppKit -framework CoreText
./test-engine
```

公開測試使用程式產生的字檔，涵蓋互換、開放鏈、來源衝突、集合字檔、輸出驗證、連續確認、誤植追查、撤回、錯誤輸入與保存。沒有包含使用者字檔。

1.1 新增抽樣數量驗證、不重複抽樣、繁簡篩選與介面轉換、問題字導航、中途建議／未抽樣報告，以及 1.0 進度檔相容性測試。

## English overview

Import one or two outline fonts, review randomly presented characters against a macOS reference and Mandarin transliteration, then press **Enter** to confirm and advance. If a glyph depicts another character, type it and press Enter: GlyphCheck follows that character next to investigate mapping chains.

Reviews are saved locally. Export missing/repaired/unresolved/pending reports and optionally generate a separately named repaired font using human-confirmed donors only. Conflicts and unknown donors are not guessed. GlyphCheck does not draw missing glyphs or repair shaping tables.

## MAKOTO LAB 與支持專案

[MAKOTO LAB](https://makotolab.tw/) 是我的獨立軟硬體實驗室，把好奇心與實際需求做成工具和產品。

如果 GlyphCheck 幫你找回了對的字，歡迎透過 [Buy Me a Coffee 贊助](https://buymeacoffee.com/MakotoLab) 支持後續開發。也歡迎回報問題或提出改進；提交 issue 時請避免上傳沒有分享授權的完整字檔或含個人資料的進度檔。

## License

MIT License. Dependencies retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). User fonts retain their original licenses and are not distributed here.
