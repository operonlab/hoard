<!-- doctype: reference -->
# Hoard UI 研究筆記（P2-D）

抓取日期一律為 2026-10-20。證據等級：

- **一手**：Apple 官方頁（developer.apple.com / apple.com / support.apple.com）或廠商自己的說明頁，本人以 WebFetch 讀過。
- **二手**：媒體或第三方技術文章，本人讀過。
- **轉述**：研究子代理讀過、帶回摘要，本人未親自抓取。引用時視為待驗證。
- **搜尋摘要**：只看到搜尋引擎的摘要，沒有讀到原頁。

`ui-spec.md` 以 `[S#]` 引用本檔。

讀取方式：developer.apple.com 的文件頁是 JavaScript 渲染，直接抓 HTML 拿不到內文。改抓同站的資料端 `https://developer.apple.com/tutorials/data/<path>.json`，其中 `metadata.platforms` 就是 API 的可用版本。先拿已知答案的 `NavigationSplitView`（macOS 13.0）當對照組驗過這條路（S5），再批次抓。

## A. Apple 設計語言（macOS 27 / iOS 27，WWDC 2026）

| # | 來源 | 等級 | 拿到什麼 |
|---|---|---|---|
| S1 | https://developer.apple.com/design/whats-new/ | 一手 | HIG 變更紀錄。**2026-06-08**：SF Symbols 8 beta、Icon Composer 2 beta、macOS 27 UI Kit（Sketch）；Design principles 重新引入；Sidebars 更新「sidebar icon colors」並釐清「adaptable sidebar style」；Scroll views 更新 scroll edge effects；Search fields、Searching 更新用語；Menus 更新選單項目圖示；新影片「Principles of great design」「Design intuitive search experiences」。**2026-03-24**：Sheets 更新按鈕位置。**2026-09-09**：Layout 更新。**2026-09-17**：macOS 27 UI Kit for Figma。**2026-10-13**：Widgets、Live Activities。Materials 頁最近一次更新仍是 2025-09-09。 |
| S2 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/materials.json | 一手 | 材質系統仍叫 **Liquid Glass**，2026 年沒有改名。Liquid Glass 是浮在內容層之上的「控制與導覽」功能層；變體 `regular`、`clear`；原文「Don't use Liquid Glass in the content layer」「Use Liquid Glass effects sparingly」「Standard system components adopt it automatically」。外觀會隨使用者在設定裡選的 Liquid Glass 外觀、「降低透明度」「增加對比」改變。macOS 段只談標準材質、vibrancy、blending mode。API：`glassEffect(_:in:)`、`Glass.regular`、`Glass.clear`、`Material`。 |
| S3 | https://support.apple.com/en-us/127257 | 一手 | macOS 27 即 macOS Golden Gate。「Updates to Liquid Glass improve readability」；「a new slider lets you customize how it looks, from ultra-clear to fully tinted」；「Uniform toolbars, edge-to-edge sidebars, and more detailed app icons」。 |
| S4 | https://www.macrumors.com/2026/06/08/apple-announces-macos-golden-gate/ | 二手 | 2026-06-08 發表。「apps now have a unified toolbar at the top」；「sidebars now extend to the edge of the window」；Apple 引述「more uniform refraction and improved contrast」。正式版預計 9 月。 |
| S5 | https://developer.apple.com/tutorials/data/documentation/swiftui/navigationsplitview.json | 一手 | 對照組。`NavigationSplitView` macOS 13.0+。 |
| S6 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/sidebars.json | 一手 | 側邊欄圖示預設用 app 的強調色，使用者改系統強調色時圖示要跟著變；固定色只在「少量使用、有明確意義」時用。側邊欄最多兩層。要能隱藏，macOS 可放顯示／隱藏按鈕並在「顯示方式」選單提供 Show Sidebar／Hide Sidebar；不要預設隱藏。視窗縮小時可自動收起側邊欄。「Avoid putting critical information or actions at the bottom of a sidebar」。列高與圖示大小跟隨使用者在「一般」設定裡選的側邊欄圖示大小。變更紀錄：2026-06-08 更新圖示顏色。API：`ListStyle.sidebar`、`NavigationSplitView`、`backgroundExtensionEffect()`。 |
| S7 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/toolbars.json | 一手 | 工具列三區：前緣（返回／前進、側邊欄控制、標題，不可自訂）、中央（常用控制，視窗變窄時自動收進系統溢出選單）、後緣（重要項目、開啟檢閱器的按鈕、搜尋欄位、主要動作，任何寬度都可見）。群組最多三個。「Make every toolbar item available as a command in the menu bar」。偏好無邊框的系統符號而非文字。少用工具列背景與上色控制。視窗標題不要用 app 名稱、15 字元內。不要自己加溢出選單。變更紀錄最新 2025-12-16。 |
| S8 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/searching.json | 一手 | 用說明性的提示文字、範圍列或標題讓人知道正在搜尋哪裡；搜尋紀錄要能清除。2026-06-08 更新用語。API：`searchSuggestions(_:)`。 |
| S9 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/search-fields.json | 一手 | macOS：多數情況把搜尋欄位放在工具列後緣，適合分割視圖、結果顯示在內容區的 app。範圍列用來在明確類別間篩選，預設較寬的範圍。「If possible, start search immediately when a person types」。API：`searchable(text:placement:prompt:)`、`NSSearchField`。 |
| S10 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/progress-indicators.json | 一手 | 能用確定型就用確定型；能確定時長時從不確定切換成確定。「Don't switch from the circular style to the bar style」。進度要準、速度要平均。指示器要一直動，停住會被當成當機。說明文字要具體，「Avoid vague terms like loading」。可中斷就提供取消。位置要固定。macOS：背景作業用小轉圈，「Avoid labeling a spinning progress indicator」。API：`ProgressView`。 |
| S11 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/alerts.json | 一手 | 警示少用；不要只為告知而跳警示；「Avoid displaying alerts for common, undoable actions, even when they're destructive」；不要在啟動時跳警示。標題要具體，不用「錯誤」。按鈕用動詞，取消鍵一律叫「取消」，不要用「好」當預設鍵（純告知除外）。使用者刻意選的破壞性動作，確認鈕不套 destructive 樣式。「Note that you don't want to make a Cancel button the default button」；想讓人讀完內容時可以不設預設鍵。Esc 與 ⌘. 可取消。macOS：`exclamationmark.triangle` 只在可能意外遺失資料時用，「Don't use the symbol for tasks whose only purpose is to overwrite or remove data, such as a save or empty trash」。 |
| S12 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/split-views.json | 一手 | macOS：設定合理的窗格最小／最大寬度，避免分隔線消失；允許隱藏窗格，並提供多種方式（工具列按鈕、選單命令、快捷鍵）叫回來；偏好 1 pt 細分隔線。本頁沒有談檢閱器。 |
| S13 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/sheets.json | 一手 | 2026-03-24 更新按鈕位置。提供「完成」就要搭「取消」或「返回」；三者不要同時出現。macOS 工作表浮在父視窗上、父視窗變暗；預設尺寸要合適。API：`sheet(item:onDismiss:content:)`。 |
| S14 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/typography.json | 一手 | 「**macOS doesn't support Dynamic Type**」。macOS 內建文字樣式：Large Title 26、Title 1 22、Title 2 17、Title 3 15、Headline 13 粗、Body 13、Callout 12、Subheadline 11、Footnote 10、Caption 1／2 10（pt）。預設 13 pt，最小 10 pt。系統字型 SF Pro。（頁面過長，只讀了前 100,000 字元。） |
| S15 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/color.json | 一手 | 不要只靠顏色傳達資訊。自訂顏色要提供淺色、深色，各自再有增加對比版本。「Even if your app ships in a single appearance mode, provide both light and dark colors to support Liquid Glass adaptivity」。不要寫死系統色數值，用 `Color` API。macOS 強調色：使用者選「多色」以外時取代 app 的強調色（固定色的側邊欄圖示除外）。Liquid Glass 本身無色、少量上色。（只讀前 100,000 字元。） |
| S16 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/accessibility.json | 一手 | 文字最好能放大到 200%。macOS 預設 13 pt、最小 10 pt。對比（WCAG AA）：17 pt 以下 4.5:1，18 pt 以上或粗體 3:1；淺色、深色都要檢查。紅綠、藍橘對色盲難分，要加形狀或圖示。減少動態效果：減少縮放、移動，改用淡入淡出，不要動畫進出模糊。完整鍵盤操作。macOS 控制尺寸預設 28×28 pt、最小 20×20 pt。 |
| S17 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/privacy.json | 一手 | 只在真的需要時、等使用者用到功能時才要權限，不要在啟動時要。說明句要主動語態、具體。系統提示之前的自訂說明畫面只放一個「繼續」類按鈕。本頁沒有談完整磁碟取用權限、被拒後怎麼辦、系統設定深層連結。 |
| S18 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/onboarding.json | 一手 | 讓人馬上開始用；用操作教學而非說明頁；必要的前置流程要短；給合理預設值、延後非必要設定；需要權限時在第一次用到該功能時才要。 |
| S19 | https://developer.apple.com/tutorials/data/design/human-interface-guidelines/sf-symbols.json | 一手 | 頁面內容仍寫 SF Symbols 7（變更紀錄最新 2025-07-28）。渲染模式 monochrome／hierarchical／palette／multicolor；可變顏色用來表示數值變化。 |
| S20 | https://developer.apple.com/sf-symbols/ | 一手 | 下載檔名 `SF-Symbols-27.dmg`；超過 7,000 個符號；新符號「available in apps running iOS 27, iPadOS 27, macOS 27…」。頁面沒寫版本號。與 S1 的「SF Symbols 8 beta」並列，現行版本的正式名稱查不到定論。 |
| S21 | https://developer.apple.com/tutorials/data/documentation/technologyoverviews/adopting-liquid-glass.json | 一手 | 用 SwiftUI／AppKit 標準元件、以最新 SDK 建置，就會自動拿到新外觀。工具列、側邊欄、分割視圖上的自訂背景會干擾 Liquid Glass，應移除。「Consider using split views to build sidebar layouts with an inspector panel」。不要在彈出視窗加自己的 visual effect view。新增 `glass`／`glassProminent` 按鈕樣式。系統元件會自動因應「降低透明度」「減少動態效果」與 Liquid Glass 外觀設定。（只讀前 100,000 字元。） |
| S22 | https://developer.apple.com/videos/wwdc2026/ | 一手 | WWDC26 場次清單。設計：Principles of great design（250）、Design intuitive search experiences（292）、Craft clear names for features and labels in your app（290）。SwiftUI：What's new in SwiftUI（269）等。AppKit：Modernize your AppKit app（289）。無障礙：Refine accessibility for custom controls（220）。清單中沒有標題含 Liquid Glass 的場次。 |
| S23 | https://developer.apple.com/videos/play/wwdc2026/269/ | 一手 | What's new in SwiftUI：Liquid Glass 新外觀不需改碼；系統 Liquid Glass 滑桿會自動調整色調；工具列 `visibilityPriority(_:)`、`ToolbarOverflowMenu`、`.topBarPinnedTrailing`；`confirmationDialog(_:item:)`、`alert(_:item:)` 以 item 綁定；`reorderable()`；`@State` 改為 macro；選單列預設只顯示少量圖示。 |
| S24 | https://developer.apple.com/videos/play/wwdc2026/250/ | 一手 | 八個設計原則：Purpose、Agency（「An interface should never stand in the way」，包含容易復原、破壞性動作要確認）、Responsibility（尊重隱私，在對的時機才要資料）、Familiarity（「things that look the same should behave the same」）、Flexibility、Simplicity（「When we say simple, we don't mean minimal」，有時是補上脈絡）、Craft、Delight。 |
| S25 | https://developer.apple.com/videos/play/wwdc2026/220/ | 一手 | 自訂控制的無障礙：讓用途、數值、動作、回饋都能被輔助技術取得。API：`accessibilityElement()`、`accessibilityLabel(_:)`、`accessibilityValue(_:)`、`AccessibilityNotification.Announcement(_:).post()`、自訂動作。 |
| S26 | https://developer.apple.com/videos/play/wwdc2026/290/ | 一手 | 命名：信任敏感的地方先求清楚；「A name that passes judgment, even unintentionally, breaks that trust」；為使用者命名而非為技術；把候選名放進日常句子裡試讀；使用者執行的動作用動詞；沿用介面裡既有的詞彙。 |

## B. SwiftUI／Foundation API 可用版本（docs JSON 的 `platforms`）

全部是一手。只列 macOS 欄位；本專案部署目標是 macOS 14（`Package.swift`）。

| # | API | macOS | 備註 |
|---|---|---|---|
| S27 | `View.inspector(isPresented:content:)`（`…/swiftui/view/inspector(ispresented:content:).json`） | 14.0 | 在寬版面是後緣欄；搭 `InspectorCommands` 取得預設命令與快捷鍵 |
| S28 | `View.glassEffect(_:in:)` | 26.0 | |
| S29 | `View.backgroundExtensionEffect()` | 26.0 | |
| S30 | `ToolbarSpacer` | 26.0 | |
| S31 | `ToolbarOverflowMenu` | **不支援** | 只列 iOS、iPadOS、Mac Catalyst、visionOS 27.0。macOS 由系統自動管理溢出（S7） |
| S32 | `View.confirmationDialog(_:item:titleVisibility:actions:message:)` | 12.0 | 與 S23 說 item 綁定是新功能不一致，見 ui-spec §13 |
| S33 | `ContentUnavailableView` | 14.0 | 有 `.search`、`init(label:description:actions:)` |
| S34 | `View.accessibilityChildren(children:)` | 12.0 | 官方範例正是替 `Canvas` 畫的圖表提供逐項元素 |
| S35 | `View.accessibilityRotor(_:entries:)` | 13.0 | |
| S36 | `View.onKeyPress(_:action:)` | 14.0 | |
| S37 | `View.scrollEdgeEffectStyle(_:for:)` | 26.0 | |
| S38 | `Table`、`Table.init(of:selection:sortOrder:columns:rows:)` | 12.0 | 表格本身不排序，要在 `onChange(of: sortOrder)` 自己排 |
| S39 | `EnvironmentValues.appearsActive` | 10.15 | |
| S40 | `View.contextMenu(forSelectionType:menu:primaryAction:)` | 13.0 | macOS 雙擊列執行 primaryAction |
| S41 | `ByteCountFormatStyle` | 12.0 | |
| S42 | `Date.RelativeFormatStyle` | 12.0 | `presentation` 有 `.numeric`／`.named`；頁面提醒相對日期字串宜單獨使用，嵌進句子可能不合文法 |
| S43 | `EnvironmentValues.accessibilityReduceMotion` | 10.15 | |
| S44 | `EnvironmentValues.accessibilityDifferentiateWithoutColor` | 10.15 | |
| S45 | `View.navigationSubtitle(_:)`（LocalizedStringResource 版） | 13.0 | macOS 上與標題一起顯示在標題列 |

抓不到（404）：HIG `changelog.json`、`view/visibilitypriority(_:).json`、`table/init(_:children:columns:).json`。這三個的 macOS 可用版本未驗證。

## C. 完整磁碟取用權限（FDA）

| # | 來源 | 等級 | 拿到什麼 |
|---|---|---|---|
| S46 | https://developer.apple.com/forums/thread/114452 | 一手（Apple 論壇；DTS 工程師回覆） | Apple DTS（Quinn，2019-03）：不建議讀 TCC 資料庫判斷，「the location and permissions of the TCC database is not considered API」；「A better option is to do what you're really trying to do and then handle errors accordingly」；權限錯誤來源很多（FDA、Data Vaults、SIP、沙盒、ACL、UNIX 權限），難以區分。社群做法：讀 `/Library/Preferences/com.apple.TimeMachine.plist` 試探；用 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` 開到對應設定頁，「You still have to tell the user about the "+" button」；上 Mac App Store 會被拒。2024 年仍有人提需求要 API（FB13511819），沒有官方回覆。 |
| S47 | https://developer.apple.com/forums/thread/670923 | 一手（Apple 論壇；DTS 工程師回覆） | Apple DTS（2021-01）：app 不能自己加進 FDA，「the user must give their consent by explicitly enabling them」；也沒有 API 讓 app 自動出現在清單裡。 |
| S48 | MacScripter「Privacy settings full disk access」、LiveCode 論壇（搜尋結果） | 搜尋摘要 | 較新的設定 pane ID `com.apple.settings.PrivacySecurity.extension`＋anchor `Privacy_AllFiles`；沙盒 app 開不了。未讀原頁。 |
| S49 | https://helpcenter.veeam.com/docs/agentformac/userguide/installation_full_disk_access.html（搜尋結果） | 搜尋摘要 | Ventura 到 Tahoe 的手動路徑：系統設定 › 隱私權與安全性 › 完整磁碟取用權限。 |

## D. macOS 儲存空間設定與檔案時間戳記

| # | 來源 | 等級 | 拿到什麼 |
|---|---|---|---|
| S50 | https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac | 一手 | 路徑：系統設定 › 一般 › 儲存空間。建議項目：儲存在 iCloud、最佳化儲存空間、自動清空垃圾桶（「more than 30 days」）。空間不足時系統會自動清快取與記錄。 |
| S51 | https://support.apple.com/guide/mac-help/change-storage-settings-on-mac-mchl3d437fbc/mac | 一手 | 文件類別可快速看大檔案或下載項目，可依「名稱、種類、上次取用、大小」排序（原文 Last Accessed）；「File Browser」看資料夾用量；刪除：選檔案按「刪除」，或「在 Finder 中顯示」。頁面沒寫刪除會不會進垃圾桶、有沒有確認。 |
| S52 | https://eclecticlight.co/2025/10/24/be-careful-when-interpreting-apfs-timestamps/ | 二手 | 引 Apple APFS 參考：沒有 `APFS_FEATURE_STRICTATIME` 時，讀檔只在 access_time 早於 mod_time 時才更新它；留言者稱 macOS 的 Data 卷沒用 strictatime 掛載。Quick Look 不會更新「修改」或「上次打開」。作者結論：「it could be extremely misleading to assume that a file hasn't been viewed」。Finder 的「上次打開」是 atime 還是 `com.apple.lastuseddate#PS` 延伸屬性，文中與留言意見分歧。 |
| S53 | https://eclecticlight.co/2025/12/20/explainer-storage-settings/ | 轉述 | 儲存空間的建議項目「limited usefulness」；文件可看大檔案、較舊的下載、不支援的 App、依大小排序的欄位瀏覽器。測於 macOS Tahoe 26.2。 |

## E. 其他磁碟工具

| # | 來源 | 等級 | 拿到什麼 |
|---|---|---|---|
| S54 | https://daisydiskapp.com/guide/3/en/DeletingFiles | 一手 | 刪除先放進 Collector，按「Delete」才動手；拒收 `/System`、`/Library`、家目錄；按下後有 5 秒可取消；「DaisyDisk permanently removes files and folders instead of moving them to the system Trash」；「These files cannot be "undeleted"」。 |
| S55 | https://daisydiskapp.com/guide/4/en/TipsAndTricks/ | 轉述 | 旭日圖（sunburst），依大小排序，太小的項目合併；點選側邊欄或圖上的資料夾往下鑽；⌘⌫ 加入 Collector。 |
| S56 | https://daisydiskapp.com/guide/3/en/DisksOverview/ | 轉述 | 首頁列出已掛載磁碟與用量條，開機磁碟在最前；綠色表示至少一半空間可用、紅色是「clear call to action」；可掃整顆磁碟、拖入資料夾、「Scan Folder…」。 |
| S57 | https://daisydiskapp.com/guide/3/en/AdminScan/ | 轉述 | 「Scan as Administrator」只在官網版、只對本機 HFS+ 卷有效。 |
| S58 | https://diskanalyzer.com/ | 轉述 | WizTree：目錄樹＋矩形樹圖，直接讀 NTFS MFT；檔案清單預設前 1000 大。 |
| S59 | https://www.pcworld.com/article/2036835/review-find-out-whats-taking-up-space-on-your-drive-in-seconds-with-wiztree.html | 搜尋摘要（轉述） | 2013 年評測：背景有檔案變動時不會更新。 |
| S60 | https://grandperspectiv.sourceforge.net/HelpDocumentation/AboutGrandPerspective.html | 轉述 | 矩形樹圖，每個檔案一個矩形，同資料夾的檔案放在一起。 |
| S61 | https://grandperspectiv.sourceforge.net/HelpDocumentation/Views.html | 轉述 | 範例以資料夾上色；滑過時在視窗底部顯示名稱與大小。 |
| S62 | https://macpaw.com/support/cleanmymac/knowledgebase/space-lens | 轉述 | Space Lens 用大小不一的泡泡；先選位置（預設主磁碟）再按掃描。 |
| S63 | https://macpaw.com/support/cleanmymac/knowledgebase/concepts-and-usage | 轉述 | 選取的項目先進清理清單，檢查過才移除。 |
| S64 | https://kb.uwm.edu/78468 | 轉述 | 儲存空間的大檔案欄位：名稱、種類、上次取用、大小（大學 IT 說明頁，非 Apple）。 |

## F. 現有程式（本 repo，讀於 2026-10-20，commit b5f6f05）

| # | 位置 | 拿到什麼 |
|---|---|---|
| S65 | `Sources/ScanCore/FileTree.swift` `Node` | 每個節點只有 `modTime`，**沒有存取時間**；有 `status`（三態）、`totalAlloc`、`rawAlloc`、`linkCount`、`cloneID`、`fileCount`、`dirCount`。 |
| S66 | `Sources/ScanCore/Scanner.swift` `ScanProgress` | 掃描進度只有 `files`、`dirs`、`bytes`、`elapsed`，沒有目前路徑、沒有總量估計。 |
| S67 | `Sources/ScanCore/LiveUpdater.swift` 變更回報、`Snapshot.swift` `SnapshotMeta` | 即時更新只回報聚合數（`dirsRescanned`、`nodesAdded`、`nodesRemoved`、`bytesDelta`）；snapshot 每次存檔覆寫，沒有逐項差異，也沒保留上一版。 |
| S68 | `Sources/HoardApp/*.swift`、`docs/progress/shots/A-fullscan.png`、`B-cached-largest.png` | 現況：自繪按鈕列＋左目錄樹（NSOutlineView）＋右上矩形樹圖（Canvas，只為深色調過，固定白字）＋右下副檔名表；最大檔案用分段控制切換；FDA 提示是橙色橫幅；丟到垃圾桶用 sheet 確認；「≥ X ⚠︎」「—」已實作；`Package.swift` 部署目標 macOS 14。 |
