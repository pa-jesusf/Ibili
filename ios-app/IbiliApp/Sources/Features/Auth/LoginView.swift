import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var vm = LoginViewModel()
    @FocusState private var inputIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Ibili")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(IbiliTheme.accent)
                        .padding(.top, 32)
                    Picker("登录方式", selection: Binding(get: { vm.method }, set: {
                        inputIsFocused = false
                        vm.select($0)
                    })) {
                        ForEach(LoginMethod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(vm.isSendingSMS)
                    .accessibilityLabel("登录方式")

                    GlassSurface(cornerRadius: 20) {
                        VStack(spacing: 20) {
                            if let risk = vm.phoneRisk {
                                riskForm(risk)
                            } else {
                                loginForm
                            }
                            if let message = vm.message {
                                Text(message).font(.footnote).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            if vm.isBusy { ProgressView("正在处理…") }
                        }
                        .padding(24)
                    }

                    if vm.phoneRisk == nil {
                        Button {
                            inputIsFocused = false
                            vm.submit()
                        } label: {
                            Text(vm.method == .qr ? "刷新二维码" : "登录")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isBusy)

                        Text(privacyNote)
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(IbiliTheme.background.ignoresSafeArea())
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .tint(IbiliTheme.accent)
        }
        .onAppear {
            vm.bind(session: session)
            if vm.method == .qr, vm.state == .idle { vm.start() }
        }
        .onDisappear { vm.cancel() }
        .sheet(item: Binding(get: { vm.captcha }, set: { if $0 == nil { vm.cancelCaptcha() } })) { challenge in
            LoginCaptchaView(challenge: challenge, onSuccess: vm.completeCaptcha, onCancel: vm.cancelCaptcha)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var loginForm: some View {
        switch vm.method {
        case .qr:
            Text("使用哔哩哔哩 App 扫码登录").font(.headline)
            qrCodeBlock
        case .password:
            Text("账号密码登录").font(.headline)
            TextField("邮箱 / 手机号", text: $vm.username)
                .textContentType(.username).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).focused($inputIsFocused).disabled(vm.isBusy)
            SecureField("密码", text: $vm.password)
                .textContentType(.password).textFieldStyle(.roundedBorder)
                .focused($inputIsFocused).disabled(vm.isBusy)
            Link("忘记密码？", destination: URL(string: "https://passport.bilibili.com/h5-app/passport/login/findPassword")!)
                .font(.footnote)
        case .sms:
            Text("短信验证码登录").font(.headline)
            HStack {
                Text("+")
                TextField("区号", text: $vm.countryCode)
                    .frame(width: 60).keyboardType(.numberPad)
                    .accessibilityLabel("国际区号")
                TextField("手机号", text: $vm.phone)
                    .textContentType(.telephoneNumber).keyboardType(.phonePad)
            }
            .textFieldStyle(.roundedBorder).focused($inputIsFocused).disabled(vm.isBusy)
            TextField("短信验证码", text: $vm.smsCode)
                .textContentType(.oneTimeCode).keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder).focused($inputIsFocused).disabled(vm.isBusy)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = vm.smsCooldownRemaining(at: context.date)
                Button(remaining > 0 ? "\(remaining) 秒后重新获取" : "获取验证码") {
                    inputIsFocused = false
                    vm.sendSMS()
                }
                .buttonStyle(.bordered).disabled(vm.isBusy || remaining > 0)
            }
        case .cookie:
            Text("Cookie 登录").font(.headline)
            Text("从你自己的哔哩哔哩登录会话导入，至少包含 SESSDATA；建议包含 bili_jct 和 DedeUserID。")
                .font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $vm.cookie)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 150).scrollContentBackground(.hidden)
                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($inputIsFocused).disabled(vm.isBusy)
                .privacySensitive().accessibilityLabel("Cookie")
        }
    }

    private func riskForm(_ risk: LoginPhoneRisk) -> some View {
        VStack(spacing: 16) {
            Text("验证绑定手机号").font(.headline)
            Text(risk.phone).font(.title3)
            TextField("安全验证短信", text: $vm.riskCode)
                .textContentType(.oneTimeCode).keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder).focused($inputIsFocused).disabled(vm.isBusy)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = vm.riskCooldownRemaining(at: context.date)
                Button(remaining > 0 ? "\(remaining) 秒后重新获取" : "获取安全验证短信") {
                    inputIsFocused = false
                    vm.sendRiskSMS()
                }
                .buttonStyle(.bordered).disabled(vm.isBusy || remaining > 0)
            }
            Button("验证并登录") { inputIsFocused = false; vm.verifyRiskSMS() }
                .buttonStyle(.borderedProminent).disabled(vm.isBusy)
            Button("取消验证", action: vm.cancelRiskVerification)
                .font(.footnote)
                .disabled(vm.isSendingSMS)
        }
    }

    @ViewBuilder
    private var qrCodeBlock: some View {
        switch vm.state {
        case .idle, .loadingQR:
            ProgressView().frame(width: 220, height: 220)
        case .waiting(let url), .scanned(let url):
            QRCodeImage(payload: url)
                .frame(width: 220, height: 220).padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            Text(isScanned ? "已扫码，请在手机上确认" : "等待扫码")
                .font(.subheadline).foregroundStyle(.secondary)
        case .expired:
            Label("二维码已过期，请刷新", systemImage: "arrow.clockwise.circle")
                .frame(minHeight: 180)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(minHeight: 180)
        case .success:
            Label("登录成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var isScanned: Bool {
        if case .scanned = vm.state { return true }
        return false
    }

    private var privacyNote: String {
        switch vm.method {
        case .password: return "密码使用哔哩哔哩提供的公钥在本地加密后传输，不保存账号密码；仅保存登录凭证。"
        case .sms: return "手机号和验证码仅用于哔哩哔哩登录接口，不予保存。国际区号可直接修改。"
        case .cookie: return "Cookie 等同于账号凭证，请勿分享给他人。Cookie 登录不含 App access_token，部分 App 专属功能可能不可用。"
        case .qr: return "登录凭证仅保存在本机，请从可信渠道安装 Ibili。"
        }
    }
}
