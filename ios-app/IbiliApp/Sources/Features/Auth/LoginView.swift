import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var vm = LoginViewModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.1, green: 0.05, blue: 0.15)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                Text("Ibili")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(IbiliTheme.accent)

                GlassSurface(cornerRadius: 20) {
                    VStack(spacing: 18) {
                        Text("使用哔哩哔哩 App 扫码登录")
                            .font(.headline)
                            .foregroundStyle(.white)
                        qrCodeBlock
                        statusLabel
                    }
                    .padding(24)
                }
                .frame(maxWidth: 320)

                Spacer()

                Button {
                    vm.start()
                } label: {
                    Text(buttonTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(IbiliTheme.accent)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            vm.bind(session: session)
            if case .idle = vm.state { vm.start() }
        }
        .onDisappear { vm.cancel() }
    }

    @ViewBuilder
    private var qrCodeBlock: some View {
        switch vm.state {
        case .loadingQR, .idle:
            ProgressView().frame(width: 220, height: 220).tint(.white)
        case .waiting(let url), .scanned(let url):
            QRCodeImage(payload: url)
                .frame(width: 220, height: 220)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        case .expired:
            VStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle").font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.7))
                Text("二维码已过期").foregroundStyle(.white)
            }.frame(width: 220, height: 220)
        case .failed(let m):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40))
                    .foregroundStyle(.yellow)
                Text(m).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
            }.frame(width: 220, height: 220).padding(8)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .resizable().scaledToFit()
                .frame(width: 100, height: 100)
                .foregroundStyle(.green)
                .frame(width: 220, height: 220)
        }
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
    }

    private var statusText: String {
        switch vm.state {
        case .idle: return "正在准备…"
        case .loadingQR: return "获取二维码…"
        case .waiting: return "等待扫码"
        case .scanned: return "已扫码，请在手机上确认"
        case .expired: return "二维码已过期，请刷新"
        case .failed(let m): return "失败：\(m)"
        case .success: return "登录成功"
        }
    }

    private var buttonTitle: String {
        switch vm.state {
        case .expired, .failed: return "刷新二维码"
        default: return "重新生成"
        }
    }
}
