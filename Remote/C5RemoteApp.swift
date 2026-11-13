import SwiftUI
import UIKit

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
                        roundKey("power", label: "关闭电视", size: 48) {
                            tv.confirmPowerOff = true
                        }
                        .disabled(tv.state != .ready)
                    }
                    .overlay { connectionStatus }

                    if tv.state == .ready {
                        trackpad.frame(height: max(185, geometry.size.height - 266))
                        HStack {
                            roundKey("chevron.left", label: "返回", size: 78, iconSize: 28) { tv.press("BACK") }
                            Spacer()
                            roundKey("tv", label: "主页", size: 78, iconSize: 28) { tv.press("HOME") }
                        }
                        volumeControl
                            .contextMenu { Button("断开连接") { disconnectManually() } }

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
            if phase == .background, tv.state != .disconnected {
                tv.disconnect()
            } else if phase == .active, !editingAddress {
                tv.reconnectIfPaired()
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
            Text(tv.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("电视 IP 地址", text: $tv.address)
                    .font(.system(.subheadline, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .focused($editingAddress)
                    .disabled(tv.state == .connecting)
                    .onSubmit(connect)
                Button(tv.state == .connecting ? "取消" : "连接") {
                    if tv.state == .connecting { disconnectManually() }
                    else { connect() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .remoteGlass(in: Capsule())
            }
            if tv.state == .disconnected {
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
