# C5 Remote

给 LG webOS 电视用的 iPhone 遥控器。App 无账号、无后端，通过家庭局域网直连电视。在触控板上滑动移动焦点，轻点确认。左上角切换输入源，右上角关机。下方是返回、主页和音量。长按音量条可断开连接。iOS 26 及更新版本使用原生 Liquid Glass，较旧版本显示磨砂材质。

## 安装到 iPhone

1. 解压后，在 Mac 用 Xcode 打开 `C5Remote.xcodeproj`。
2. 选择 C5Remote target，在 **Signing & Capabilities** 选自己的 Team。若 Xcode 提示 Bundle Identifier 已占用，改成自己独有的标识。
3. 连接 iPhone（iOS 17 或更新版本），选为运行设备，再点 **Run**。按手机提示启用开发者模式（如有提示）。

## 配对电视

1. 打开电视，让 iPhone 和电视接入同一个家庭网络。
2. 在电视网络设置中查看 IPv4 地址，例如 `192.168.1.50`。
3. 在 App 输入 IP，点「连接」。允许 iOS 的本地网络访问，并在电视弹窗选择允许。
4. 下次打开 App，点「连接」即可复用本机保存的电视授权。如果电视的 IP 变了，请填新地址。若电视已重置，先在 App 点「清除配对」，再重新授权。

电源键用于关机。要开始新一次连接，先用电视实体遥控器开机。App 使用加密 WebSocket，首次在电视上确认配对后记录该电视的证书指纹，之后复用配对时校验指纹。

webOS 遥控协议参考 [aiowebostv](https://github.com/home-assistant-libs/aiowebostv)。
