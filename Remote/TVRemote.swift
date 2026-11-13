import CryptoKit
import Foundation
import Network
import Security
import SwiftUI

private final class TVTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let host: String
    private var pin: String?

    init(host: String, pin: String?) {
        self.host = host
        self.pin = pin
    }

    var fingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return pin
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.host == host,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let presented = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)).base64EncodedString()
        lock.lock()
        if pin == nil { pin = presented }
        let matches = pin == presented
        lock.unlock()
        completionHandler(matches ? .useCredential : .cancelAuthenticationChallenge,
                          matches ? URLCredential(trust: trust) : nil)
    }
}

@MainActor
final class TVRemote: ObservableObject {
    enum State {
        case disconnected, connecting, ready
    }

    struct Input: Identifiable {
        let id: String
        let label: String
    }

    private struct Pairing: Codable {
        let key: String
        let fingerprint: String
    }

    @Published var showingInputs = false
    @Published private(set) var inputs: [Input] = []
    @Published private(set) var loadingInputs = false
    @Published var confirmPowerOff = false
    @Published var address = UserDefaults.standard.string(forKey: "lastTV") ?? ""
    @Published private(set) var state = State.disconnected
    @Published private(set) var status = "输入电视的 IP 地址"
    @Published private(set) var commandError: String?

    private var session: URLSession?
    private var control: URLSessionWebSocketTask?
    private var pointer: URLSessionWebSocketTask?
    private var timeout: Task<Void, Never>?
    private var powerRequest: String?
    private var inputRequest: String?
    private var inputTimeout: Task<Void, Never>?

    private var reconnectPaused = false

    func disconnectManually() {
        reconnectPaused = true
        disconnect()
    }

    var hasSavedPairing: Bool {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserDefaults.standard.string(forKey: "lastTV") == host && savedPairing(for: host) != nil
    }

    func reconnectIfPaired() {
        guard !reconnectPaused, state == .disconnected, hasSavedPairing else { return }
        connect()
    }

    private func savedPairing(for host: String) -> Pairing? {
        UserDefaults.standard.data(forKey: "tvPairing." + host)
            .flatMap { try? JSONDecoder().decode(Pairing.self, from: $0) }
    }

    func connect(timeoutSeconds: Int = 60) {
        reconnectPaused = false
        disconnect()
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ip = IPv4Address(host) else {
            status = "请输入 IPv4 地址，例如 192.168.1.50"
            return
        }
        let bytes = Array(ip.rawValue)
        guard bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) else {
            status = "请输入电视的家庭局域网 IP 地址"
            return
        }

        address = host
        UserDefaults.standard.set(host, forKey: "lastTV")
        let storageKey = "tvPairing." + host
        let saved = savedPairing(for: host)
        let trust = TVTrust(host: host, pin: saved?.fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 65
        let session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: URL(string: "wss://\(host):3001")!)
        control = socket
        state = .connecting
        status = "连接中 · 首次配对请在电视上点允许"
        socket.resume()

        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled, let self, self.control === socket else { return }
            self.disconnect("连接超时，请检查 IP、网络和电视上的配对提示")
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                var payload: [String: Any] = [
                    "pairingType": "PROMPT",
                    "forcePairing": false,
                    "manifest": [
                        "manifestVersion": 1,
                        "appVersion": "1.0",
                        "permissions": [
                            "CONTROL_AUDIO", "CONTROL_INPUT_TV", "CONTROL_MOUSE_AND_KEYBOARD",
                            "CONTROL_POWER", "CONTROL_INPUT_JOYSTICK", "LAUNCH", "READ_INPUT_DEVICE_LIST"
                        ]
                    ]
                ]
                if let saved { payload["client-key"] = saved.key }
                try await self.send(["id": "pair", "type": "register", "payload": payload], to: socket)
                while self.control === socket {
                    let message = try await socket.receive()
                    guard self.control === socket else { return }
                    let data: Data
                    switch message {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let body = response["payload"] as? [String: Any]
                    let id = response["id"] as? String
                    if response["type"] as? String == "error" || body?["returnValue"] as? Bool == false {
                        let reason = response["error"] as? String ?? body?["errorText"] as? String ?? "电视拒绝了请求"
                        if self.state == .connecting {
                            self.disconnect("配对失败 · " + reason)
                            return
                        }
                        self.commandError = reason
                        if self.inputRequest == id { self.finishInputRequest() }
                        if self.powerRequest == id { self.powerRequest = nil }
                        continue
                    }
                    if response["type"] as? String == "registered", self.state == .connecting {
                        if let key = body?["client-key"] as? String ?? saved?.key,
                           let fingerprint = trust.fingerprint {
                            let data = try JSONEncoder().encode(Pairing(key: key, fingerprint: fingerprint))
                            UserDefaults.standard.set(data, forKey: storageKey)
                        }
                        try await self.send([
                            "id": "pointer", "type": "request",
                            "uri": "ssap://com.webos.service.networkinput/getPointerInputSocket",
                            "payload": [:]
                        ], to: socket)
                    }
                    if id == "pointer", self.state == .connecting {
                        guard let path = body?["socketPath"] as? String,
                              var endpoint = URLComponents(string: path),
                              endpoint.host == host, ["ws", "wss"].contains(endpoint.scheme ?? ""),
                              endpoint.user == nil, endpoint.password == nil else {
                            self.disconnect("电视返回了无效的遥控连接地址")
                            return
                        }
                        endpoint.scheme = "wss"
                        endpoint.port = 3001
                        guard let url = endpoint.url else {
                            self.disconnect("无法打开遥控连接")
                            return
                        }
                        let pointer = session.webSocketTask(with: url)
                        self.pointer = pointer
                        pointer.resume()
                        try await self.ping(pointer)
                        guard self.control === socket else { return }
                        self.timeout?.cancel()
                        self.state = .ready
                        self.status = "已连接 · " + host
                    }
                    if let id, self.inputRequest == id {
                        let devices = body?["devices"] as? [[String: Any]] ?? []
                        self.inputs = devices.compactMap { device in
                            guard let inputID = device["id"] as? String, !inputID.isEmpty else { return nil }
                            let label = (device["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? inputID
                            return Input(id: inputID, label: label)
                        }
                        self.finishInputRequest()
                    }
                    if let id, self.powerRequest == id {
                        self.disconnect("电视已关机")
                        return
                    }
                }
            } catch {
                guard self.control === socket else { return }
                if self.powerRequest != nil {
                    self.disconnect("连接已断开，请检查电视是否关机")
                } else {
                    self.disconnect("连接断开 · " + error.localizedDescription)
                }
            }
        }
    }

    func disconnect(_ message: String = "未连接") {
        timeout?.cancel()
        timeout = nil
        pointer?.cancel(with: .goingAway, reason: nil)
        control?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        pointer = nil
        control = nil
        session = nil
        powerRequest = nil
        finishInputRequest()
        showingInputs = false
        inputs = []
        commandError = nil
        state = .disconnected
        status = message
    }

    func forgetTV() {
        disconnect("已清除配对，请在电视上重新授权")
        UserDefaults.standard.removeObject(forKey: "tvPairing." + address.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func press(_ name: String) {
        guard state == .ready, let pointer else { return }
        commandError = nil
        Task {
            do {
                try await pointer.send(.string("type:button\nname:\(name)\n\n"))
            } catch {
                guard self.pointer === pointer else { return }
                disconnect("遥控连接断开，请重新连接")
            }
        }
    }

    func volume(_ up: Bool) {
        request(up ? "audio/volumeUp" : "audio/volumeDown")
    }

    func powerOff() {
        guard powerRequest == nil else { return }
        request("system/turnOff", isPower: true)
    }

    func openInputs() {
        guard state == .ready, inputRequest == nil else { return }
        showingInputs = true
        loadingInputs = true
        inputs = []
        let id = UUID().uuidString
        inputRequest = id
        request("tv/getExternalInputList", id: id)
        inputTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.inputRequest == id else { return }
            self.finishInputRequest()
            self.commandError = "读取输入源超时，请重试"
        }
    }

    func selectInput(_ input: Input) {
        showingInputs = false
        request("tv/switchInput", payload: ["inputId": input.id])
    }

    private func finishInputRequest() {
        inputTimeout?.cancel()
        inputTimeout = nil
        inputRequest = nil
        loadingInputs = false
    }

    private func request(_ path: String, payload: [String: Any] = [:],
                         id: String = UUID().uuidString, isPower: Bool = false) {
        guard state == .ready, let socket = control else { return }
        commandError = nil
        if isPower { powerRequest = id }
        Task {
            do {
                try await send(["id": id, "type": "request", "uri": "ssap://" + path, "payload": payload], to: socket)
            } catch {
                guard control === socket else { return }
                disconnect("连接断开 · " + error.localizedDescription)
            }
        }
    }

    private func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func send(_ message: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
