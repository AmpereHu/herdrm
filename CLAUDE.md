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
  （保存於 `~/Library/Application Support/HerdrM/devices.json`）、`HerdrService` 外觀層。
- `Sources/HerdrM` — SwiftUI 應用程式（XcodeGen `project.yml`），內嵌 SwiftTerm 終端機。
- `design/` — 設計畫布的工作檔（`*.dc.html` 畫板 + `canvas.json`）。

## 建置與測試

```sh
make build      # xcodegen + xcodebuild → build/Build/Products/Debug/HerdrM.app
make run
make kit-test   # HerdrKit 整合測試（需要本機有執行中的 herdr）
HERDRM_E2E_SSH_TARGET=vincent@10.10.10.87 make kit-test   # 另外跑遠端 SSH E2E 測試
```

xcodebuild 需要加上 `-skipPackagePluginValidation`（SwiftTerm 內含一個 build plugin），
Makefile 已經帶上這個參數。

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

參考用的 repo：`~/Projects/herdr`（伺服器原始碼）、`~/Projects/Heeler`（iOS 用戶端，
共用同一套領域模型）、`~/Projects/waku`（側邊欄設計參考）。
