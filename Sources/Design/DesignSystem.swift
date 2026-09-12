import SwiftUI

enum LayoutMetrics {
    static let pageInset: CGFloat = 24
    static let sectionSpacing: CGFloat = 24
    static let contentSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    static let compactSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 8

    static let listMinimumWidth: CGFloat = 240
    static let listIdealWidth: CGFloat = 300
    static let detailMinimumWidth: CGFloat = 320
}

extension HealthSeverity {
    var color: Color {
        switch self {
        case .healthy: .green
        case .notice: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct StatusLabel: View {
    let severity: HealthSeverity
    var compact = false

    var body: some View {
        Label(severity.label, systemImage: severity.symbolName)
            .font(compact ? .caption : .callout)
            .fontWeight(.medium)
            .foregroundStyle(severity.color)
            .labelStyle(.titleAndIcon)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status")
            .accessibilityValue(severity.label)
    }
}

struct ProvenanceBadge: View {
    let provenance: DataProvenance

    var body: some View {
        Text(provenance.rawValue)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Data source: \(provenance.rawValue.lowercased())")
    }
}

struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.contentSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: LayoutMetrics.contentSpacing)
            trailing()
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct InsetPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(.background, in: RoundedRectangle(cornerRadius: LayoutMetrics.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: LayoutMetrics.cornerRadius)
                    .stroke(.separator.opacity(0.6), lineWidth: 0.5)
            }
    }
}

struct CapacityMeter: View {
    let volume: VolumeSnapshot
    var width: CGFloat?

    var body: some View {
        ProgressView(value: volume.usedFraction) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .tint(volume.capacityTint)
        .frame(width: width)
        .accessibilityLabel("Capacity used")
        .accessibilityValue(MetricFormatter.percentage(volume.usedFraction))
    }
}

extension VolumeSnapshot {
    var capacitySeverity: HealthSeverity {
        if availableFraction < 0.10 { return .critical }
        if availableFraction < 0.20 { return .warning }
        return .healthy
    }

    var capacityTint: Color {
        capacitySeverity == .healthy ? .accentColor : capacitySeverity.color
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: symbol,
            description: Text(message)
        )
    }
}
