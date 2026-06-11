import SwiftUI

enum SurfaceState: Hashable {
    case loading(title: String = "正在加载")
    case empty(title: String, systemImage: String, message: String? = nil)
    case error(title: String = "加载失败", systemImage: String = "wifi.exclamationmark", message: String? = nil)
}

struct StateView: View {
    let state: SurfaceState
    var retryTitle: String? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            switch state {
            case .loading(let title):
                ProgressView()
                    .tint(IbiliTheme.accent)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(IbiliTheme.textSecondary)
            case .empty(let title, let systemImage, let message),
                 .error(let title, let systemImage, let message):
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }

            if let onRetry {
                Button(retryTitle ?? "重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(IbiliTheme.accent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

