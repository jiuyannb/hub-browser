# 黄片大王（HubBrowser）

iOS 16+ 多站点聚合浏览器 + 磁力搜索。SwiftUI + WKWebView，未签名 IPA 由 GitHub Actions 云端编译。

## 功能

**站点聚合**
- 视频：Pornhub / XVideos / XNXX / Hanime / MissAV / Jable / Supjav / Netflav / AVGLE / SpankBang / Eporner / 91Porn
- 漫画：禁漫天堂 / 禁漫备用 / Hitomi / nhentai / E-Hentai
- 磁力：Sukebei / JavDB / Btdig / BTSOW
- 综合：Rule34 / NudeCelebs

**浏览**
- WKWebView 内核，导航显示网页标题，前进/后退/刷新/停止 + 进度条
- 无痕模式（非持久化数据存储）、广告与弹窗拦截（WKContentRuleList）
- 桌面版 UA 切换（部分站点移动端排版差时用）
- `target=_blank` 在当前页打开，不弹白窗
- 页面加载后自动隐藏 fixed 高 z-index 遮挡层
- 屏蔽 magnet / thunder / ed2k / itms-services / intent 等外部协议跳转

**播放**
- 点击 `.m3u8 / .mp4 / .flv` 直链自动转 AVPlayer 全屏播放
- 倍速 0.5×–2×、画中画、AirPlay、后台音频、播完自动重播
- 播放页菜单可直接把直链丢进下载队列

**磁力**
- 8 个磁力搜索引擎（Sukebei / Btdig / JavDB / 1337x / PirateBay / TorrentGalaxy / BTSOW / BT4G）
- 网页里点任何磁力链接 → 弹出操作面板：复制 / 用外部下载器打开 / 内置在线播放
- 剪贴板一键读取磁力、最近 50 条磁力记录
- 内置 WebTorrent 播放器（实验：只对支持 WebRTC 的种子有效）

**下载**
- mp4 直链下载到沙盒 `Documents/Downloads`，带进度
- 下载完可一键存进系统相册

**其他**
- 收藏、浏览历史（300 条）、单独清 Cookie 与缓存
- 全局搜索：跳到第一个配置了 `{q}` 模板的站点

## 拿 IPA

仓库已配好 `.github/workflows/build.yml`，push 到 main 自动编译。

Actions → `build-ipa` → 等绿色 → 页面底部 **Artifacts** → 下载 `HubBrowser-unsigned-ipa` → 解压得 `HubBrowser.ipa`。

产物是**未签名包**，用全能签 / Sideloadly 签名安装。

## 改站点

编辑 `Sources/Models.swift` 的 `Site.defaults`：

```swift
Site(name: "显示名",
     url: "https://域名",
     category: "视频",                                  // 视频 / 漫画 / 磁力 / 综合
     searchTemplate: "https://域名/search?q={q}",        // 没站内搜索写 nil
     icon: "play.rectangle.fill")                       // SF Symbols 名
```

改完 commit，Actions 自动重编。

## 已知限制

- DRM / FairPlay 加密流播不了（WKWebView 拿不到密钥）
- 部分站点检测 WKWebView 或要登录 Cookie，白屏时先开桌面版 UA
- 图片漫画站若因拦广告白屏，关掉「拦截广告」重进
- 磁力实质下载必须靠外部 BT 客户端：iOS 不允许后台跑 BT，WebTorrent 只能连 WebRTC peer
- 超长图会被系统回收内存后重画

## 结构

```
project.yml                 XcodeGen 工程（Bundle ID: com.yg.hubbrowser）
Resources/Info.plist        显示名「黄片大王」+ ATS 全开 + 后台音频 + 相册权限
Sources/App.swift           入口
Sources/Models.swift        Site / MagnetEngine / Bookmark / Prefs / 站点清单
Sources/AppStore.swift      全局状态 + 持久化 + 清缓存
Sources/BrowserModel.swift  WKWebView：KVO、JS 注入、广告规则、导航拦截、磁力回调
Sources/BrowserScreen.swift 浏览页 + 底栏
Sources/MagnetView.swift    磁力搜索 + 磁力操作面板
Sources/TorrentPlayer.swift WebTorrent 实验播放器
Sources/PlayerSheet.swift   AVPlayer 全屏播放（倍速/画中画）
Sources/DownloadManager.swift URLSession 下载 + 存相册
Sources/RootView.swift      四个 Tab + 下载管理
.github/workflows/build.yml macOS 14 编译并打包未签名 IPA
```
