# C5 Remote

给 LG webOS 电视用的 iPhone 遥控器。App 无账号、无后端，通过家庭局域网直连电视。在触控板上滑动移动焦点，轻点确认。左上角切换输入源，右上角关机。下方是返回、主页和音量。长按音量条可断开连接。iOS 26 及更新版本使用原生 Liquid Glass，较旧版本显示磨砂材质。

点音量旁边的太阳图标可读取当前画质模式的 OLED 像素亮度。开启电视的 Network IP Control，首次输入电视生成的密钥，拖动滑杆后点「应用」。App 通过 IP Control 写入，再读回亮度确认。验证成功后，密钥保存在本机钥匙串，清除电视配对时一并移除。点「开启自动亮度」可发送电视的自动节能指令，在电视的「节能步骤」里确认是否生效。

## 安装到 iPhone

1. 解压后，在 Mac 用 Xcode 打开 `C5Remote.xcodeproj`。
2. 选择 C5Remote target，在 **Signing & Capabilities** 选自己的 Team。若 Xcode 提示 Bundle Identifier 已占用，改成自己独有的标识。
3. 连接 iPhone（iOS 17 或更新版本），选为运行设备，再点 **Run**。按手机提示启用开发者模式（如有提示）。

## 配对电视

1. 打开电视，让 iPhone 和电视接入同一个家庭网络。
2. 在电视网络设置中查看 IPv4 地址，例如 `192.168.1.50`。
3. 在 App 输入 IP，点「连接」。允许 iOS 的本地网络访问，并在电视弹窗选择允许。
4. 之后打开 App 或回到前台时，会自动连接已配对且开机的电视。手动断开或取消后，本次使用期间可以点「连接」恢复。如果电视的 IP 变了，请填新地址。若电视已重置，先在 App 点「清除配对」，再重新授权。

已连接时电源键用于关机。断开时，电源键可以通过 Apple 家庭开机。先把电视添加到 Apple「家庭」并确认能从那里开机，再授权 C5 Remote 访问家庭、选择电视。发出开机指令后，App 会尝试重新连接已配对的电视。安装此版本需要支持 HomeKit capability 的签名团队。App 使用加密 WebSocket，首次在电视上确认配对后记录该电视的证书指纹，之后复用配对时校验指纹。

webOS 遥控协议参考 [aiowebostv](https://github.com/home-assistant-libs/aiowebostv)。
