import SwiftUI

/// Settings row that opens the tailnet list.
struct TailnetSettingsRow: View {
    @EnvironmentObject private var model: AppModel

    private var summary: String {
        let enabled = model.tailnets.filter(\.isEnabled).count
        guard !model.tailnets.isEmpty else {
            return String(localized: "代理时也能访问家里电脑等 Tailscale 设备。")
        }
        return String(localized: "已启用 \(enabled) 个，写入支持的客户端配置。")
    }

    var body: some View {
        NavigationLink {
            TailnetListView()
        } label: {
            HStack(spacing: 8) {
                SettingsRowLabel(symbol: "network", color: .indigo, title: "Tailscale 内网", resolvedDetail: summary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TailnetListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: TailnetEditorItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("代理客户端开着的时候，也能通过 Tailscale 访问家里的电脑和局域网。塔台把它写成一个单独的策略，只有 Tailscale 地址、MagicDNS 和你填写的子网会走它，其他流量不受影响。")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("支持 Surge（iOS 5.21 / Mac 6.8 起）、Stash 3.4 起、Clash / mihomo（内核 1.19.25 起）和 sing-box MT。Stash 默认跳过 Tailscale 地址段，请用 MagicDNS 设备名访问。Shadowrocket、Loon、Quantumult X、Egern、Hiddify 和 Karing 暂不支持，导出时会跳过并提示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .towerCard()

                if !model.tailnets.isEmpty {
                    VStack(spacing: 14) {
                        ForEach(model.tailnets) { connection in
                            TailnetRow(connection: connection) {
                                editing = TailnetEditorItem(connection: connection, isNew: false)
                            }
                            if connection.id != model.tailnets.last?.id { Divider() }
                        }
                    }
                    .padding(17)
                    .towerCard()
                }

                Button {
                    editing = TailnetEditorItem(connection: TailnetConnection(name: TailnetConnection.defaultName), isNew: true)
                } label: {
                    Label("添加 Tailscale 内网", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ResponsivePressButtonStyle())
                .towerCard()
                .accessibilityIdentifier("tailnet-add")
            }
            .padding(.horizontal, TowerTheme.pagePadding)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .background(TowerTheme.background.ignoresSafeArea())
        .navigationTitle("Tailscale 内网")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { item in
            TailnetEditorSheet(item: item)
        }
    }
}

struct TailnetEditorItem: Identifiable {
    let connection: TailnetConnection
    let isNew: Bool
    var id: UUID { connection.id }
}

private struct TailnetRow: View {
    @EnvironmentObject private var model: AppModel
    let connection: TailnetConnection
    let edit: () -> Void

    private var detail: String {
        var parts: [String] = [
            connection.magicDNSSuffix ?? (connection.customControlURL == nil
                ? String(localized: "官方控制服务器")
                : String(localized: "自建控制服务器")),
        ]
        if !connection.subnets.isEmpty {
            parts.append(String(localized: "\(connection.subnets.count) 个子网"))
        }
        if model.hasTailnetAuthKey(connection.id) {
            parts.append(String(localized: "已保存 Auth Key"))
        }
        return parts.joined(separator: " · ")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { connection.isEnabled }, set: { model.setTailnetEnabled(connection.id, $0) })
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: edit) {
                HStack(spacing: 13) {
                    SettingsIconTile(symbol: "network", color: .indigo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: connection.policyName).font(.headline)
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("编辑"))

            Toggle(isOn: enabledBinding) {
                Text(verbatim: connection.policyName)
            }
            .labelsHidden()
        }
    }
}

private struct TailnetEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: TailnetEditorItem

    @State private var name: String
    @State private var controlURL: String
    /// The key as it stands in the field. Filled from the Keychain when the
    /// sheet opens; clearing it and saving removes the saved key.
    @State private var authKey = ""
    @State private var savedAuthKey: String?
    @State private var revealsAuthKey = false
    @State private var subnets: String
    @State private var magicDNSSuffix: String
    @State private var deviceName: String
    @State private var errorMessage: String?
    @State private var requestsDiscard = false
    @State private var confirmsDelete = false

    init(item: TailnetEditorItem) {
        self.item = item
        let connection = item.connection
        _name = State(initialValue: connection.name)
        _controlURL = State(initialValue: connection.controlURLString ?? "")
        _subnets = State(initialValue: connection.subnets.joined(separator: "\n"))
        _magicDNSSuffix = State(initialValue: connection.magicDNSSuffix ?? "")
        _deviceName = State(initialValue: connection.deviceName ?? "")
    }

    private var hasChanges: Bool {
        let connection = item.connection
        return name != connection.name || controlURL != (connection.controlURLString ?? "")
            || authKey != (savedAuthKey ?? "")
            || subnets != connection.subnets.joined(separator: "\n")
            || magicDNSSuffix != (connection.magicDNSSuffix ?? "")
            || deviceName != (connection.deviceName ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                    TextField("控制服务器（留空为官方 Tailscale）", text: $controlURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("连接")
                } footer: {
                    Text("使用 Headscale 等自建服务时填写它的 HTTPS 地址。")
                }

                Section {
                    AuthKeyField(key: $authKey, isRevealed: $revealsAuthKey)
                } header: {
                    Text("Auth Key（可选）")
                } footer: {
                    Text("Stash、Clash / mihomo 和 sing-box MT 需要它；Surge 在自己的策略编辑页里登录，不写入 Auth Key。生成时请打开 Reusable；设备加入后，在 Tailscale 后台的 Machines 页面为它关闭 Key Expiry。只存在这台设备的钥匙串，不同步到 iCloud。")
                }

                Section {
                    TextField("例如 192.168.1.0/24", text: $subnets, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("tailnet-subnets")
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("家里子网（可选）")
                } footer: {
                    Text("需要家里有一台设备在 Tailscale 里发布这个子网并获批准。每行一个。")
                }

                Section {
                    TextField("例如 tail1234.ts.net", text: $magicDNSSuffix)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("设备名（默认 tower）", text: $deviceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("MagicDNS 与设备名")
                } footer: {
                    Text("MagicDNS 后缀在 Tailscale 管理后台的 DNS 页面可以找到，用于按设备名访问。每个客户端会注册成单独的设备，例如 tower-surge。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if !item.isNew {
                    Section {
                        Button("删除这个 Tailscale 内网", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .navigationTitle(item.isNew ? "添加 Tailscale 内网" : "编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { requestsDiscard = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .accessibilityIdentifier("tailnet-save")
                }
            }
            .confirmDiscardChanges(hasChanges: hasChanges, isBusy: false, requested: $requestsDiscard) {}
            .onAppear {
                guard savedAuthKey == nil, let key = model.tailnetAuthKey(for: item.connection.id) else { return }
                savedAuthKey = key
                authKey = key
            }
            .confirmationDialog("删除这个 Tailscale 内网？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    model.deleteTailnet(item.connection.id)
                    dismiss()
                }
            } message: {
                Text("导出的配置里不会再包含它，这台设备上保存的 Auth Key 也会一并删除。")
            }
        }
    }

    private func save() {
        errorMessage = nil
        var connection = item.connection
        do {
            connection.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if connection.name.isEmpty { connection.name = TailnetConnection.defaultName }
            connection.controlURLString = try TailnetConnection.normalizedControlURL(controlURL)
            connection.subnets = try TailnetConnection.normalizedSubnets(subnets)
            connection.magicDNSSuffix = try TailnetConnection.normalizedMagicDNSSuffix(magicDNSSuffix)
            connection.deviceName = TailnetConnection.normalizedDeviceName(deviceName)
            let key = try TailnetConnection.normalizedAuthKey(authKey)
            let change: AppModel.TailnetAuthKeyChange = switch (key, savedAuthKey) {
            case (nil, nil): .keep
            case (nil, _?): .remove
            case (let key?, let saved): key == saved ? .keep : .set(key)
            }
            try model.saveTailnet(connection, authKey: change)
            dismiss()
        } catch let error as TailnetConnection.ValidationError {
            errorMessage = switch error {
            case .controlURL: String(localized: "控制服务器必须是 HTTPS 地址。")
            case .subnet(let value): String(localized: "无法识别的子网“\(value)”，请用 192.168.1.0/24 这样的格式。")
            case .magicDNSSuffix: String(localized: "MagicDNS 后缀格式不对，例如 tail1234.ts.net。")
            case .authKey: String(localized: "Auth Key 不能包含空格、引号或逗号。")
            }
        } catch {
            errorMessage = String(localized: "无法保存到钥匙串，请重试。")
        }
    }
}

/// One field for the whole life of the key: it opens showing the saved key
/// masked, the eye reveals it for checking, and editing it in place is how it
/// is replaced or (by clearing it) removed. The same pattern as a password in
/// the Passwords app.
private struct AuthKeyField: View {
    @Binding var key: String
    @Binding var isRevealed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isRevealed {
                    // A key is ~60 characters; wrapping shows all of it.
                    TextField("tskey-auth-…", text: $key, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.callout.monospaced())
                } else {
                    SecureField("tskey-auth-…", text: $key)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.none)
            .accessibilityIdentifier("tailnet-auth-key")

            if key.isEmpty {
                PasteButton(payloadType: String.self) { strings in
                    guard let value = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    key = value
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            } else {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRevealed ? Text("隐藏 Auth Key") : Text("显示 Auth Key"))
            }
        }
    }
}
