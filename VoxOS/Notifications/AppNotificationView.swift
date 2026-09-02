import SwiftUI

struct AppNotificationView: View {
    let title: String
    let type: NotificationType
    let duration: TimeInterval
    let onClose: () -> Void
    let onTap: (() -> Void)?
    var actionButton: (label: String, action: () -> Void)? = nil

    @State private var progress: Double = 1.0
    @State private var timer: Timer?

    enum NotificationType {
        case error
        case warning
        case info
        case success

        var iconName: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .error: return AppTheme.Status.error
            case .warning: return AppTheme.Status.warning
            case .info: return AppTheme.Status.info
            case .success: return AppTheme.Status.success
            }
        }
    }

    var body: some View {
        ZStack {
            HStack(alignment: .center, spacing: 12) {
                // Type icon
                Image(systemName: type.iconName)
                    .font(.app(size: 16, weight: .medium))
                    .foregroundColor(type.iconColor)
                    .frame(width: 20, height: 20)

                // Single message text
                Text(title)
                    .font(.app(size: 12, weight: .regular))
                    .fontWeight(.medium)
                    .foregroundColor(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()

                if let actionButton {
                    Button(action: {
                        actionButton.action()
                        onClose()
                    }) {
                        Text(actionButton.label)
                            .font(.app(size: 11, weight: .semibold))
                            .foregroundColor(Color.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.app(size: 10, weight: .medium))
                        .foregroundColor(Color.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 220, maxWidth: 750, minHeight: 44)
        .liquidGlass(cornerRadius: AppTheme.Radius.card)
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous).stroke(AppTheme.Notch.rim, lineWidth: 1))
        )
        .overlay(
            // Subtle inner border
            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .overlay(
            VStack {
                Spacer()
                GeometryReader { geometry in
                    Rectangle()
                        .fill(type.iconColor.opacity(0.8))
                        .frame(width: geometry.size.width * max(0, progress), height: 2)
                        .animation(.linear(duration: 0.1), value: progress)
                }
                .frame(height: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        )
        .onAppear {
            startProgressTimer()
        }
        .onDisappear {
            timer?.invalidate()
        }
        .onTapGesture {
            if let onTap = onTap {
                onTap()
                onClose()
            }
        }
    }

    private func startProgressTimer() {
        let updateInterval: TimeInterval = 0.1
        let totalSteps = duration / updateInterval
        let stepDecrement = 1.0 / totalSteps

        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { _ in
            if progress > 0 {
                progress = max(0, progress - stepDecrement)
            } else {
                timer?.invalidate()
                timer = nil
            }
        }
    }
}
