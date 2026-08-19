<p align="center">
  <img src="Resources/AppIcon/herdrm-icon-rounded.png" width="128" alt="herdrm icon" />
</p>

<h1 align="center">herdrm</h1>

<p align="center">
  <a href="https://herdr.dev">herdr</a> 的原生 macOS 主控台 —
  一眼看盡所有機器上的每一個編碼代理人，並直接跳進它的即時終端機。
</p>

---

> [!WARNING]
> 早期階段的軟體，測試覆蓋率尚不完整 — 出現 bug 是預期中的事。非常歡迎送 PR！

<p align="center">
  <img src=".github/assets/screenshot.png" alt="herdrm — 裝置切換器與一個執行中的 claude 終端機" />
</p>

## 這個 App 能做什麼

[herdr](https://herdr.dev) 是你的編碼代理人賴以執行的 runtime：一個背景伺服器，
掌管它們的終端機、讓它們持續執行，並且知道哪一個正在工作、被卡住、或已經完成。
**herdrm** 則在它之上加了一個原生的 macOS 視窗：

- **所有裝置，同時連線** — 本機的 herdr 再加上任意數量的遠端機器（透過 SSH，
  遠端的 socket 是用 `ssh -L` 轉送過來的，所以操作起來完全一樣）。每個裝置都會
  保持連線並自動重連；側邊欄會把它們全部匯總在一起，每一列都有一個帶底色的名稱標籤
  標示它屬於哪台機器，左下角的切換器則可以依裝置過濾。
- **Spaces 與 Agents 側邊欄** — 列出每一個 herdr 工作區與每一個代理人
  （claude、codex、gemini、grok、opencode 等）以及即時狀態：被卡住的代理人會浮到
  最上面，工作中的會轉圈，完成的會打勾。
- **即時終端機** — 選取一個代理人就會直接接上它的 PTY（`herdr agent attach`）。
  完整的 TUI、精準的游標，沒有多餘的聊天外殼。最近看過的終端機會保持附掛，
  加上 ssh 連線多工，來回切換幾乎沒有延遲；連線斷掉時會直接給你重新連線的按鈕。
- **通知** — 任何裝置上的任何代理人完成工作或需要你回應時，都會發出系統通知；
  通知會直接顯示代理人問的那句話，你可以就在通知裡輸入答案送回去，或是點一下
  跳到那個代理人。你正在看的代理人則不會發通知。
- **New Agent** — 在任何裝置的任何 space 裡啟動代理人。選單只會列出該裝置上實際
  已安裝的 CLI，並預設幫每個代理人開啟它自己的略過權限旗標
  （例如 claude 的 `--dangerously-skip-permissions`）。
- **選單列與 Dock** — 常駐選單列圖示列出所有裝置上被卡住或已完成的代理人，
  Dock 圖示標示待回應數量，不必把視窗叫到前面也知道現在該處理誰。
- **鍵盤操作** — ⌥⌘↑／⌥⌘↓ 切換代理人、⌘1–9 直接跳、⌘K 搜尋、⌘N 開新代理人。
  方向鍵本身留給終端機裡的 TUI。
- **搜尋** — ⌘K 命令面板，可跨所有裝置搜尋代理人與 space。
- **淺色與深色主題**，透過 Sparkle 自動更新，已簽章並完成公證。

## 系統需求

- macOS 14 以上
- 本機和／或遠端機器上有執行中的 [herdr](https://herdr.dev)
- 遠端裝置：需要 SSH 金鑰存取權（herdrm 會使用你本機的金鑰／ssh-agent）

## 安裝

### Homebrew

```sh
brew install owo-network/brew/herdrm
```

### 手動安裝

到 [Releases](https://github.com/missuo/herdrm/releases) 下載最新的
`herdrm-x.y.z.zip`，解壓縮後把 `herdrm.app` 拖進 `/Applications`。
不論用哪一種方式，之後 App 都會自行更新。

## 從原始碼建置

```sh
brew install xcodegen
make build   # xcodegen + xcodebuild → build/Build/Products/Debug/herdrm.app
make run
make kit-test  # HerdrKit 整合測試（需要本機有執行中的 herdr）
```

## 架構

- `Packages/HerdrKit` — Swift 套件：對應 herdr socket API 的 NDJSON over Unix
  socket RPC 用戶端、SSH 通道管理、裝置儲存。
- `Sources/HerdrM` — SwiftUI 應用程式；終端機內嵌使用
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)。

## 致謝

- [herdr](https://herdr.dev) — 給編碼代理人使用的終端機工作區管理器，
  本 App 正是它的主控台。
- [Heeler](https://github.com/ZingerLittleBee/Heeler) — herdr 的 iOS 用戶端；
  herdrm 借鏡了它的領域模型與傳輸層設計。
- [waku](https://github.com/egoist/waku) — 側邊欄的設計參考。
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — 終端機模擬。
- [Sparkle](https://sparkle-project.org) — 自動更新。
- [Lobe Icons](https://github.com/lobehub/lobe-icons) 與
  [Simple Icons](https://simpleicons.org) — 代理人與作業系統的品牌圖示。
