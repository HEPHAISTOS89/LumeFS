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
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .tracking(0.4)
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
    @AppStorage("capacityWarningThreshold") private var warningPercent = 20.0
    @AppStorage("capacityCriticalThreshold") private var criticalPercent = 10.0
    let volume: VolumeSnapshot
    var width: CGFloat?

    private var severity: HealthSeverity {
        volume.capacitySeverity(thresholds: CapacityThresholds(
            warningFreeFraction: warningPercent / 100,
            criticalFreeFraction: criticalPercent / 100
        ))
    }

    var body: some View {
        ProgressView(value: volume.usedFraction) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .tint(severity == .healthy ? .accentColor : severity.color)
        .frame(width: width)
        .accessibilityLabel("Capacity used")
        .accessibilityValue(MetricFormatter.percentage(volume.usedFraction))
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

struct CapacityStatusView: View {
    let volume: VolumeSnapshot
    @AppStorage("capacityWarningThreshold") private var warningPercent = 20.0
    @AppStorage("capacityCriticalThreshold") private var criticalPercent = 10.0

    var body: some View {
        let severity = volume.capacitySeverity(thresholds: CapacityThresholds(
            warningFreeFraction: warningPercent / 100,
            criticalFreeFraction: criticalPercent / 100
        ))
        Label(title(for: severity), systemImage: severity.symbolName)
            .font(.callout.weight(.medium))
            .foregroundStyle(severity.color)
    }

    private func title(for severity: HealthSeverity) -> String {
        if volume.totalBytes <= 0 { return "Capacity unknown" }
        switch severity {
        case .healthy: return "Space available"
        case .notice: return "Check capacity"
        case .warning: return "Low space"
        case .critical: return "Very low space"
        }
    }
}

/// Functional pictograms use SF Symbols so weight, contrast, accessibility and
/// platform evolution stay aligned with macOS. Custom SVGs are reserved for
/// product identity rather than recreating system controls.
struct ProductIcon: View {
    let systemName: String
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ProductLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            ProductIcon(systemName: systemImage, size: 14)
        }
    }
}

/// Persisted appearance shared by every app scene. Unknown preferences follow macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static func resolve(_ value: String) -> AppAppearance {
        AppAppearance(rawValue: value) ?? .system
    }
}
