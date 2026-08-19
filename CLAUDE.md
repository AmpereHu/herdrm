# herdrm — HerdrM

[herdr](https://herdr.dev)（給編碼代理人使用的終端機工作區管理器）的原生 macOS 主控台。
側邊欄列出 Spaces（herdr 工作區）與 Agents；左下角的頁尾用來切換裝置（本機 Local 以及
透過 SSH 連線的遠端 herdr 主機）；右側面板是純粹的內嵌終端機，執行
`herdr agent attach` — 沒有聊天輸入框。

設計畫布（waku 風格側邊欄，淺色／深色）：`design/` — 以「Herdr for Mac」artifact 發佈。
`design/canvas.json` 的註記帶有設計 token 與規格。

## 專案結構

- `Packages/HerdrKit` — SPM 函式庫：NDJSON over Unix socket 的 RPC（`SocketRPC`）、
  資料模型、`SSHTunnel`（OpenSSH `-L local.sock:remote.sock` 轉送）、`Device`／`DeviceStore`
  （保存於 `~/Library/Application Support/HerdrM/devices.json`）、`HerdrService` 外觀層，
  以及 `ConsoleLogic`／`TerminalText`。
- `Sources/HerdrM` — SwiftUI 應用程式（XcodeGen `project.yml`），內嵌 SwiftTerm 終端機。
- `design/` — 設計畫布的工作檔（`*.dc.html` 畫板 + `canvas.json`）。

### 兩個值得先知道的地方

- **`ConsoleLogic`（HerdrKit）** — 側邊欄排序、⌘K 比對、通知轉換判斷與重連退避都
  住在這裡：純函式、不碰 `@MainActor`、不需要伺服器，所以測得到。新的排序或過濾
  規則請加在這裡，不要寫回 `AppModel`。
- **`TerminalSessionStore`（App）** — 保活中的 `herdr agent attach` 程序與它們的
  SwiftTerm view，讓切換代理人不必重開程序。刻意只留 2 個背景終端機、逾時 45 秒：
  herdr 會把仍附掛的 pane 視為你正在看而壓下它的完成通知，所以離開太久的 pane
  必須放掉。

## 建置與測試

```sh
make build      # xcodegen + xcodebuild → build/Build/Products/Debug/HerdrM.app
make run
make kit-test   # HerdrKit 測試（整合測試需要本機有執行中的 herdr，沒有就自行 skip）
HERDRM_E2E_SSH_TARGET=vincent@10.10.10.87 make kit-test   # 另外跑遠端 SSH E2E 測試
```

xcodebuild 需要加上 `-skipPackagePluginValidation`（SwiftTerm 內含一個 build plugin），
Makefile 已經帶上這個參數。

`.github/workflows/ci.yml` 會在每次 push 與 PR 上以未簽章方式建置 App 並跑
`swift test`。測試分兩類：`WireFormatTests`／`ConsoleLogicTests` 是離線的（wire
format、模型解碼、排序與通知規則），`LocalSocketTests`／`RemoteSSHTests` 需要真實
的 herdr 或 SSH 目標，缺少時會自行 skip。動到 JSON 欄位名或排序規則時，請一併補
離線測試 —— 那是唯一在 CI 上真正會擋下問題的部分。

## 發佈

Repo：github.com/missuo/herdrm。推送 `v*` tag → `.github/workflows/release.yml`
會建置 Release（Developer ID：MOE AI LLC，啟用 hardened runtime）、透過 notarytool
公證、staple、對 zip 做 Sparkle 簽章、產生 `appcast.xml`，並把兩者一起發佈成 GitHub
release。所需 secrets：MACOS_CERTIFICATE_P12/_PASSWORD、APPLE_ID、APPLE_TEAM_ID、
APPLE_APP_PASSWORD、SPARKLE_PRIVATE_KEY（EdDSA 私鑰同時存放在本機的 login Keychain；
公鑰則寫死在 project.yml 裡）。Sparkle 更新來源：`releases/latest/download/` 底下的
release 資產 `appcast.xml`。版本號：MARKETING_VERSION 取自 tag，CFBundleVersion 則是
CI 的 run number。CHANGELOG.md 是必要的：CI 會擷取對應的 `## [x.y.z]` 段落作為 GitHub
release 說明與 Sparkle 的更新描述，找不到就會讓 CI 失敗 — 打 tag 前記得先補上該段落。
OwO-Network/homebrew-brew 裡的 cask 會在每次發佈後自動更新版本。

## herdr 協定筆記（0.8.0，protocol 19；已對照實際 socket 驗證）

- 請求是走 `~/.config/herdr/herdr.sock` 的 NDJSON `{"id","method","params"}`；
  即使 `params` 是空的也必須帶上（`{}`），否則伺服器會拒絕該請求。
- `tab.create` 會以 `result.root_pane.pane_id` 回傳新建立的 pane。
- `events.subscribe` 接受 `{"subscriptions":[{"type":"pane.updated"},…]}`；
  `pane.agent_status_changed`／`pane.scroll_changed`／`pane.output_matched` 是
  pane 層級的事件（需要 `pane_id`），無法全域訂閱 — 狀態變化會以 `pane.updated`
  的形式全域送達。完整的全域事件種類清單見 `HerdrEvent.allKinds`。
- 終端機 attach：`herdr agent attach <pane_id> --takeover`（從其他已連上的用戶端手中
  接管該 pane）。遠端裝置是透過 `ssh -tt` 執行並在前面補上 PATH（`sshd` 執行的不是
  login shell；herdr 在 macOS 主機上位於 `/opt/homebrew/bin`）。
- 代理人狀態分組的排序是 Blocked > Done > Working > Idle（與 Heeler 一致）。
- `snapshot.panes` 包含沒有代理人的純 shell pane；側邊欄的 Terminals 分組就是它，
  attach 走的是同一條 `herdr agent attach <pane_id>` 路徑。
- 回覆被卡住的代理人是用 `pane.send_input` 再送一個 `enter` 鍵，而不是
  `agent.prompt`：pane id 是 App 本來就握有的識別，`agent.prompt` 的 target
  選擇器語意尚未對照實際 socket 驗證過。
- 所有 ssh（socket 轉送、探測、終端機 attach）都帶 `ControlMaster=auto` 與共用的
  `ControlPath`，因此一台遠端裝置只會有一次握手成本。

參考用的 repo：`~/Projects/herdr`（伺服器原始碼）、`~/Projects/Heeler`（iOS 用戶端，
共用同一套領域模型）、`~/Projects/waku`（側邊欄設計參考）。
