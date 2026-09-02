import SwiftUI

struct AnnouncementView: View {
    let title: String
    let description: String
    let onClose: () -> Void
    let onLearnMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.app(size: 14, weight: .semibold))
                    .foregroundColor(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.app(size: 11, weight: .medium))
                        .foregroundColor(Color.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }

            if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(description)
                        .font(.app(size: 12, weight: .regular))
                        .foregroundColor(Color.primary.opacity(0.9))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            HStack(spacing: 8) {
                Button(action: onLearnMore) {
                    Text("Learn more")
                        .font(.app(size: 12, weight: .medium))
                        .foregroundColor(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onClose) {
                    Text("Dismiss")
                        .font(.app(size: 12, weight: .medium))
                        .foregroundColor(Color.primary.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 360, idealWidth: 420)
        .liquidGlass(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.Notch.rim, lineWidth: 1))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5)
        )
    }
}
