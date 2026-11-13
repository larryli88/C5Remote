import SwiftUI
import UIKit
import HomeKit

@main
struct C5RemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RemoteView()
                .preferredColorScheme(.dark)
        }
    }
}

private struct RemoteView: View {
    @StateObject private var tv = TVRemote()
    @StateObject private var homePower = HomePower()
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var editingAddress: Bool
    private let tapFeedback = UIImpactFeedbackGenerator(style: .light)
    private let swipeFeedback = UISelectionFeedbackGenerator()
    private let graphite = Color(white: 0.085)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        roundKey("cable.connector.horizontal", label: "输入源", size: 48) {
                            tv.openInputs()
                        }
                        .disabled(tv.state != .ready)
                        Spacer()
                        roundKey("power", label: tv.state == .ready ? "关闭电视" : "通过 HomeKit 开机", size: 48) {
                            if tv.state == .ready { tv.confirmPowerOff = true }
                            else {
                                editingAddress = false
                                homePower.powerOn(remote: tv)
                            }
                        }
                        .contextMenu {
                            if tv.state != .ready {
                                Button("重新选择家庭电视") { homePower.chooseAnotherTV(remote: tv) }
                            }
                        }
                        .disabled(homePower.waking || (tv.state != .ready && !homePower.isSupported))
                    }
                    .overlay { connectionStatus }

                    if tv.state == .ready {
                        trackpad.frame(height: max(185, geometry.size.height - 266))
                        HStack {
                            roundKey("chevron.left", label: "返回", size: 78, iconSize: 28) { tv.press("BACK") }
                            Spacer()
                            roundKey("tv", label: "主页", size: 78, iconSize: 28) { tv.press("HOME") }
                        }
                        HStack(spacing: 16) {
                            volumeControl
                                .contextMenu { Button("断开连接") { disconnectManually() } }
                            roundKey("sun.max", label: "OLED 像素亮度", size: 54) { tv.openBrightness() }
                        }

                        if let error = tv.commandError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        connectionCard
                    }
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(tv.state == .ready && geometry.size.height >= 440 && tv.commandError == nil)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background {
                homePower.cancel()
                if tv.state != .disconnected { tv.disconnect() }
            } else if phase == .active, !editingAddress, !homePower.waking, !homePower.showingPicker {
                tv.reconnectIfPaired()
            }
        }
        .sheet(isPresented: $homePower.showingPicker, onDismiss: homePower.clearPendingSelection) {
            NavigationStack {
                List {
                    if !homePower.loaded {
                        ProgressView("正在读取 Apple 家庭…")
                    } else if homePower.targets.isEmpty {
                        Text("请先在 Apple「家庭」添加电视，并允许 C5 Remote 访问家庭。")
                    } else {
                        ForEach(homePower.targets) { target in
                            Button(target.name) {
                                tapFeedback.impactOccurred()
                                homePower.wake(target, remote: tv)
                            }
                        }
                    }
                }
                .navigationTitle("通过家庭开机")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { homePower.showingPicker = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $tv.showingBrightness) {
            NavigationStack {
                Form {
                    if let current = tv.brightness {
                        Section {
                            if tv.brightnessWriteDenied {
                                Text("当前亮度 \(current)").monospacedDigit()
                            } else {
                                Slider(value: $tv.brightnessDraft, in: 0...100, step: 1)
                                    .accessibilityLabel("OLED 像素亮度")
                                Text("当前亮度 \(current) · 待设为 \(Int(tv.brightnessDraft))")
                                    .monospacedDigit()
                                Button("应用") { tv.applyBrightness() }
                                    .disabled(Int(tv.brightnessDraft) == current)
                            }
                        }
                        .disabled(tv.adjustingBrightness)
                    }
                    if tv.adjustingBrightness {
                        ProgressView("等待电视回应…")
                    }
                    if tv.brightnessWriteDenied {
                        Text("电视允许读取亮度。请在电视设置里调整亮度。")
                            .foregroundStyle(.secondary)
                    }
                    if let error = tv.brightnessError {
                        Text(error).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("打开电视设置") {
                            tv.openTVSettings()
                        }
                    } footer: {
                        Text("在电视的快速设置里选「所有设置 → 画面 → 高级设置 → 亮度 → OLED 像素亮度」。")
                    }
                }
                .navigationTitle("OLED 像素亮度")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { tv.showingBrightness = false }
                    }
                }
            }
        }
        .sheet(isPresented: $tv.showingInputs) {
            NavigationStack {
                List {
                    if tv.loadingInputs {
                        ProgressView("正在读取输入源…")
                    } else if let error = tv.commandError {
                        Text(error)
                    } else if tv.inputs.isEmpty {
                        Text("电视没有返回可切换的输入源")
                    } else {
                        ForEach(tv.inputs) { input in
                            Button(input.label) {
                                tapFeedback.impactOccurred()
                                tv.selectInput(input)
                            }
                        }
                    }
                }
                .navigationTitle("输入源")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { tv.showingInputs = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("关闭电视？", isPresented: $tv.confirmPowerOff, titleVisibility: .visible) {
            Button("关闭电视", role: .destructive) { tv.powerOff() }
        }
    }

    private var connectionStatus: some View {
        let connected = tv.state == .ready
        return Image(systemName: connected ? "checkmark.circle.fill" : "wifi.slash")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(connected ? Color.green : Color.secondary)
            .accessibilityLabel("电视连接状态")
            .accessibilityValue(connected ? "已连接" : tv.state == .connecting ? "连接中" : "未连接")
            .allowsHitTesting(false)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(homePower.message ?? tv.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("电视 IP 地址", text: $tv.address)
                    .font(.system(.subheadline, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .focused($editingAddress)
                    .disabled(tv.state == .connecting || homePower.waking)
                    .onSubmit(connect)
                Button(tv.state == .connecting ? "取消" : "连接") {
                    if tv.state == .connecting { disconnectManually() }
                    else { connect() }
                }
                .buttonStyle(.plain)
                .disabled(homePower.waking)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .remoteGlass(in: Capsule())
            }
            if tv.state == .disconnected, !homePower.waking {
                HStack {
                    Text("在电视的网络设置里查看 IP")
                    Spacer()
                    if !tv.address.isEmpty {
                        Button("清除配对") { tv.forgetTV() }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(graphite, in: RoundedRectangle(cornerRadius: 24))
    }

    private var trackpad: some View {
        let shape = RoundedRectangle(cornerRadius: 36)
        return shape
            .fill(graphite)
            .overlay(shape.strokeBorder(.white.opacity(0.13), lineWidth: 1))
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { gesture in moveFocus(by: gesture.translation) }
                    .exclusively(before: TapGesture().onEnded { tapFeedback.impactOccurred(); tv.press("ENTER") })
            )
            .accessibilityElement()
            .accessibilityLabel("电视触控板")
            .accessibilityHint("滑动移动焦点，轻点确认")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tapFeedback.impactOccurred(); tv.press("ENTER") }
            .accessibilityAction(named: "向上") { swipeFeedback.selectionChanged(); tv.press("UP") }
            .accessibilityAction(named: "向下") { swipeFeedback.selectionChanged(); tv.press("DOWN") }
            .accessibilityAction(named: "向左") { swipeFeedback.selectionChanged(); tv.press("LEFT") }
            .accessibilityAction(named: "向右") { swipeFeedback.selectionChanged(); tv.press("RIGHT") }
    }

    private func moveFocus(by offset: CGSize) {
        let horizontal = abs(offset.width) >= abs(offset.height)
        let distance = horizontal ? offset.width : offset.height
        guard abs(distance) >= 16 else { return }
        swipeFeedback.selectionChanged()
        if horizontal { tv.press(distance > 0 ? "RIGHT" : "LEFT") }
        else { tv.press(distance > 0 ? "DOWN" : "UP") }
    }

    private var volumeControl: some View {
        HStack(spacing: 0) {
            key("speaker.minus", label: "降低音量") { tv.volume(false) }
                .frame(width: 94, height: 54)
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 24)
                .accessibilityHidden(true)
            key("speaker.plus", label: "提高音量") { tv.volume(true) }
                .frame(width: 94, height: 54)
        }
        .remoteGlass(in: Capsule())
    }

    private func roundKey(
        _ symbol: String, label: String, size: CGFloat, iconSize: CGFloat = 22, action: @escaping () -> Void
    ) -> some View {
        key(symbol, label: label, iconSize: iconSize, action: action)
            .frame(width: size, height: size)
            .remoteGlass(in: Circle())
    }

    private func key(_ symbol: String, label: String, iconSize: CGFloat = 22, action: @escaping () -> Void) -> some View {
        Button {
            tapFeedback.impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func connect() {
        editingAddress = false
        homePower.message = nil
        tv.connect()
    }

    private func disconnectManually() {
        tv.disconnectManually()
    }
}

private extension View {
    @ViewBuilder
    func remoteGlass(in shape: some InsettableShape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 1).allowsHitTesting(false))
        }
    }
}


@MainActor
private final class HomePower: NSObject, ObservableObject, HMHomeManagerDelegate {
    struct Target: Identifiable {
        let id: UUID
        let name: String
        let power: HMCharacteristic
    }

    @Published var showingPicker = false
    @Published var message: String?
    @Published private(set) var waking = false
    @Published private(set) var loaded = false
    @Published private(set) var targets: [Target] = []

    private var manager: HMHomeManager?
    private var pendingRemote: TVRemote?
    private var wakeTask: Task<Void, Never>?

    var isSupported: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    func chooseAnotherTV(remote: TVRemote) {
        UserDefaults.standard.removeObject(forKey: "homePowerTarget")
        powerOn(remote: remote)
    }

    func powerOn(remote: TVRemote) {
        message = nil
        if let saved = UserDefaults.standard.string(forKey: "homePowerTarget"),
           let target = targets.first(where: { $0.id.uuidString == saved }) {
            wake(target, remote: remote)
            return
        }
        if !loaded { pendingRemote = remote }
        if manager == nil {
            let manager = HMHomeManager()
            self.manager = manager
            manager.delegate = self
        }
        showingPicker = true
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.updateTargets(from: manager) }
    }

    private func updateTargets(from manager: HMHomeManager) {
        loaded = true
        guard #available(iOS 18.0, *) else { return }
        targets = manager.homes.flatMap { home in
            home.accessories.flatMap { accessory in
                accessory.services.compactMap { service in
                    guard service.serviceType == HMServiceTypeTelevision,
                          let power = service.characteristics.first(where: {
                              $0.characteristicType == HMCharacteristicTypeActive
                                  && $0.properties.contains(HMCharacteristicPropertyWritable)
                          }) else { return nil }
                    return Target(id: service.uniqueIdentifier, name: "\(accessory.name) · \(home.name)", power: power)
                }
            }
        }
        let remote = pendingRemote
        pendingRemote = nil
        if showingPicker, let remote,
           let saved = UserDefaults.standard.string(forKey: "homePowerTarget"),
           let target = targets.first(where: { $0.id.uuidString == saved }) {
            wake(target, remote: remote)
        }
    }

    func clearPendingSelection() {
        pendingRemote = nil
    }

    func wake(_ target: Target, remote: TVRemote) {
        guard !waking else { return }
        UserDefaults.standard.set(target.id.uuidString, forKey: "homePowerTarget")
        showingPicker = false
        waking = true
        message = "正在通过 Apple 家庭开机…"
        wakeTask = Task {
            defer {
                if !Task.isCancelled { waking = false }
            }
            do {
                try await target.power.writeValue(NSNumber(value: HMCharacteristicValueActivationState.active.rawValue))
                try Task.checkCancellation()
                guard remote.hasSavedPairing else {
                    message = "已发送开机指令。电视开启后，请输入 IP 并连接。"
                    return
                }
                message = "等待电视启动并连接…"
                for _ in 0..<5 {
                    try Task.checkCancellation()
                    if remote.state == .disconnected { remote.connect(timeoutSeconds: 4) }
                    try await Task.sleep(for: .seconds(5))
                    if remote.state == .ready {
                        message = nil
                        return
                    }
                }
                message = "已发送开机指令，暂未连上电视。电视开启后可点「连接」。"
            } catch {
                if !Task.isCancelled { message = "Apple 家庭开机失败 · " + error.localizedDescription }
            }
        }
    }

    func cancel() {
        pendingRemote = nil
        wakeTask?.cancel()
        wakeTask = nil
        waking = false
        message = nil
    }
}
