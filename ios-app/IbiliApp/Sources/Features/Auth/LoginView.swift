import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var vm = LoginViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case username, password, country, phone, code, cookie, riskCode }

    var body: some View {
        let captchaID = vm.captcha?.id
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 28) {
                        brand
                            .padding(.top, min(44, max(24, geometry.size.height * 0.05)))

                        IbiliSegmentedTabs(tabs: LoginMethod.allCases, title: { $0.rawValue },
                            selection: Binding(get: { vm.method }, set: {
                                focusedField = nil
                                vm.select($0)
                            }))
                            .disabled(vm.isSendingSMS)
                            .accessibilityLabel("登录方式")

                        VStack(spacing: 22) {
                            if let risk = vm.phoneRisk {
                                riskForm(risk)
                            } else {
                                loginForm
                                primaryAction(vm.method == .qr ? "刷新二维码" : "登录") {
                                    submit()
                                }
                            }
                            if let message = vm.message {
                                Text(message)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(IbiliTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .tint(IbiliTheme.accent)
        }
        .onAppear {
            vm.bind(session: session)
            if vm.method == .qr, vm.state == .idle { vm.start() }
        }
        .onDisappear {
            // Covering login with verification is not leaving the login flow.
            if session.connectionState != .login { vm.cancel() }
        }
        .sheet(isPresented: Binding(get: { vm.isCaptchaPresented }, set: {
            vm.captchaPresentationChanged($0, presentationID: captchaID)
        }), onDismiss: { vm.captchaDidDismiss(presentationID: captchaID) }) {
            if let presentation = vm.captcha {
                LoginCaptchaView(challenge: presentation.challenge,
                    onSuccess: { vm.completeCaptcha($0, presentationID: presentation.id) },
                    onCancel: { vm.cancelCaptcha(presentationID: presentation.id) })
                    .id(presentation.id)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var brand: some View {
        VStack(spacing: 14) {
            Image("LoginBrand")
                .resizable()
                .scaledToFit()
                .frame(width: 156, height: 76)
                .accessibilityHidden(true)
            Text("Ibili")
                .font(.system(size: 34, weight: .bold, design: .rounded))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ibili 登录")
    }

    @ViewBuilder
    private var loginForm: some View {
        switch vm.method {
        case .qr:
            VStack(spacing: 20) {
                Text("扫码登录").font(.title3.weight(.semibold))
                qrCodeBlock
            }
            .frame(maxWidth: .infinity)
        case .password:
            VStack(spacing: 14) {
                inputGroup {
                    inputRow(symbol: "person", field: .username) {
                        TextField("邮箱 / 手机号", text: $vm.username)
                            .textContentType(.username).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .username)
                            .submitLabel(.next).onSubmit { focusedField = .password }
                    }
                    inputDivider
                    inputRow(symbol: "lock", field: .password) {
                        SecureField("密码", text: $vm.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go).onSubmit(submit)
                    }
                }
                Link("忘记密码？", destination: URL(string: "https://passport.bilibili.com/h5-app/passport/login/findPassword")!)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .trailing)
            }
        case .sms:
            inputGroup {
                inputRow(symbol: "iphone", field: .phone) {
                    HStack(spacing: 10) {
                        HStack(spacing: 2) {
                            Text("+").foregroundStyle(.secondary)
                            TextField("86", text: $vm.countryCode)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .country)
                                .accessibilityLabel("国际区号")
                        }
                        .frame(width: 60)
                        Divider().frame(height: 22)
                        TextField("手机号", text: $vm.phone)
                            .textContentType(.telephoneNumber).keyboardType(.phonePad)
                            .focused($focusedField, equals: .phone)
                    }
                }
                inputDivider
                inputRow(symbol: "number", field: .code) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { smsCodeField; smsButton }
                        VStack(alignment: .leading, spacing: 12) { smsCodeField; smsButton }
                    }
                }
            }
        case .cookie:
            inputGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Cookie", systemImage: "key.horizontal")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    ZStack(alignment: .topLeading) {
                        if vm.cookie.isEmpty {
                            Text("粘贴 Cookie")
                                .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $vm.cookie)
                            .frame(minHeight: 150).scrollContentBackground(.hidden)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .cookie)
                            .privacySensitive().accessibilityLabel("Cookie")
                    }
                    .font(.system(.body, design: .monospaced))
                }
                .padding(20)
            }
        }
    }

    private var smsCodeField: some View {
        TextField("验证码", text: $vm.smsCode)
            .textContentType(.oneTimeCode).keyboardType(.numberPad)
            .focused($focusedField, equals: .code)
            .frame(minWidth: 72)
    }

    private var smsButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = vm.smsCooldownRemaining(at: context.date)
            Button(remaining > 0 ? "\(remaining) 秒后重发" : "获取验证码") {
                focusedField = nil
                vm.sendSMS()
            }
            .font(.subheadline.weight(.semibold)).monospacedDigit()
            .buttonStyle(.plain).foregroundStyle(IbiliTheme.accent)
            .fixedSize().frame(minHeight: 44)
            .disabled(vm.isBusy || remaining > 0)
            .opacity(vm.isBusy || remaining > 0 ? 0.5 : 1)
        }
    }

    private func riskForm(_ risk: LoginPhoneRisk) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("验证绑定手机号").font(.title3.weight(.semibold))
                Text(risk.phone).font(.title2.monospacedDigit())
            }
            inputGroup {
                inputRow(symbol: "lock.shield", field: .riskCode) {
                    TextField("短信验证码", text: $vm.riskCode)
                        .textContentType(.oneTimeCode).keyboardType(.numberPad)
                        .focused($focusedField, equals: .riskCode)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = vm.riskCooldownRemaining(at: context.date)
                Button(remaining > 0 ? "\(remaining) 秒后重新获取" : "获取安全验证短信") {
                    focusedField = nil
                    vm.sendRiskSMS()
                }
                .font(.subheadline.weight(.medium)).monospacedDigit()
                .frame(minHeight: 44).disabled(vm.isBusy || remaining > 0)
            }
            primaryAction("验证并登录") { focusedField = nil; vm.verifyRiskSMS() }
            Button("取消验证", action: vm.cancelRiskVerification)
                .font(.subheadline).frame(minHeight: 44).disabled(vm.isSendingSMS)
        }
    }

    private func inputGroup<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        GlassSurface(cornerRadius: 24) {
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity)
                .textFieldStyle(.plain)
                .disabled(vm.isBusy)
        }
    }

    private func inputRow<Content: View>(symbol: String, field: Field, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(focusedField == field ? IbiliTheme.accent : IbiliTheme.textSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            content().font(.body)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(minHeight: 62)
    }

    private var inputDivider: some View {
        Divider().padding(.leading, 56).padding(.trailing, 20)
    }

    private func primaryAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if vm.isBusy { ProgressView().tint(.white) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(vm.isBusy)
    }

    private func submit() {
        focusedField = nil
        vm.submit()
    }

    @ViewBuilder
    private var qrCodeBlock: some View {
        switch vm.state {
        case .idle, .loadingQR:
            ProgressView().frame(width: 220, height: 220)
        case .waiting(let url), .scanned(let url):
            QRCodeImage(payload: url)
                .frame(width: 204, height: 204).padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text(isScanned ? "已扫码，请在手机上确认" : "使用哔哩哔哩 App 扫码")
                .font(.subheadline).foregroundStyle(.secondary)
        case .expired:
            Label("二维码已过期，请刷新", systemImage: "arrow.clockwise.circle")
                .frame(minHeight: 220)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(minHeight: 220)
        case .success:
            Label("登录成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var isScanned: Bool {
        if case .scanned = vm.state { return true }
        return false
    }
}
