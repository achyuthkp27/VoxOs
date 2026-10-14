import AppKit
import SwiftUI

struct ProviderBrandIcon: View {
    let descriptor: ProviderDescriptor
    let fallbackSystemImage: String
    let isSelected: Bool
    let size: CGFloat
    let iconSize: CGFloat

    private var hasBrandAsset: Bool {
        descriptor.brandAssetName != nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(7, size * 0.25))
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: max(7, size * 0.25))
                        .stroke(borderColor, lineWidth: 1)
                )

            if let assetName = descriptor.brandAssetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(size * 0.24)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.app(size: iconSize, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.Accent.primary : Color.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var backgroundColor: Color {
        if hasBrandAsset {
            return Color.white.opacity(isSelected ? 0.96 : 0.9)
        }
        return AppTheme.Surface.control
    }

    private var borderColor: Color {
        if isSelected {
            return AppTheme.Accent.border
        }
        return AppTheme.Border.control.opacity(hasBrandAsset ? 0.45 : 0.2)
    }
}

/// A group's mono eyebrow and one plain line on what the group is for.
struct ProviderSectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(subtitle)
                .font(.app(size: 12, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProviderConfigurationGroup<Content: View>: View {
    let title: LocalizedStringKey
    let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            content()
        }
    }
}

struct ProviderModelListSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(ProviderSurface(cornerRadius: 10))
        }
    }
}

struct ProviderSurface: View {
    var isActive: Bool = false
    var cornerRadius: CGFloat = 10

    var body: some View {
        AppMaterialCardBackground(isSelected: isActive, cornerRadius: cornerRadius)
    }
}

/// Connection state as a small capsule: tinted when connected, quiet when not.
struct ProviderStatusBadge: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.app(size: 11, weight: .medium))
                .foregroundStyle(color == .secondary ? AppTheme.Text.secondary : color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color == .secondary ? AppTheme.Surface.control : color.opacity(0.12)))
    }
}

// MARK: - Model list rows

/// Shared measurements for rows in the AI Models lists, so dividers start under the text.
enum ModelRowMetrics {
    static let iconSize: CGFloat = 36
    static let horizontalPadding: CGFloat = 14
    static let spacing: CGFloat = 12
    static let textInset: CGFloat = horizontalPadding + iconSize + spacing
}

/// One grouped container on the AI Models page: a single card, rows separated by dividers.
struct ModelListGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Surface.card)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Border.card, lineWidth: 1)
        )
    }
}

/// The divider between two rows of a `ModelListGroup`, inset to the text.
struct ModelListDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, ModelRowMetrics.textInset)
    }
}

/// The 36pt rounded tile at the start of a model row: a waveform for speech, sparkles for
/// language models.
struct ModelIconTile: View {
    let systemName: String
    var tint: Color = AppTheme.Accent.primary

    var body: some View {
        Image(systemName: systemName)
            .font(.app(size: 15, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: ModelRowMetrics.iconSize, height: ModelRowMetrics.iconSize)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
    }
}

/// One model as a list row: icon tile, name with small badges, a meta line, a description,
/// and its status or action at the end. `footer` holds progress and errors under the text.
struct ModelListRow<Badges: View, Trailing: View, Footer: View>: View {
    let systemImage: String
    var iconTint: Color = AppTheme.Accent.primary
    let name: String
    let meta: [String]
    let description: Text?
    let badges: Badges
    let trailing: Trailing
    let footer: Footer

    init(
        systemImage: String,
        iconTint: Color = AppTheme.Accent.primary,
        name: String,
        meta: [String],
        description: Text?,
        @ViewBuilder badges: () -> Badges,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder footer: () -> Footer
    ) {
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.name = name
        self.meta = meta
        self.description = description
        self.badges = badges()
        self.trailing = trailing()
        self.footer = footer()
    }

    var body: some View {
        HStack(alignment: .top, spacing: ModelRowMetrics.spacing) {
            ModelIconTile(systemName: systemImage, tint: iconTint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.app(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primary)
                        .lineLimit(1)
                    badges
                }

                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.app(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .lineLimit(1)
                }

                if let description {
                    description
                        .font(.app(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.Text.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                trailing
            }
            .frame(minHeight: ModelRowMetrics.iconSize)
        }
        .padding(.horizontal, ModelRowMetrics.horizontalPadding)
        .padding(.vertical, 12)
    }
}

/// A small capsule beside a model's name ("New", "In use").
struct ModelRowBadge: View {
    let title: LocalizedStringKey
    var isAccent = true

    var body: some View {
        Text(title)
            .font(.app(size: 10, weight: .semibold))
            .foregroundStyle(isAccent ? AppTheme.Accent.primary : AppTheme.Text.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(isAccent ? AppTheme.Accent.fill : AppTheme.Surface.control))
    }
}

/// The quiet Download action at the end of a model row.
struct ModelDownloadButton: View {
    let isDownloading: Bool
    var title: LocalizedStringKey = "Download"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isDownloading ? "Downloading…" : title, systemImage: "arrow.down")
                .font(.app(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDownloading)
    }
}

/// The ⋯ menu at the end of a model row.
struct ModelRowMenu<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}
