import SwiftUI

struct SettingsView: View {
    @AppStorage("appearancePreference") private var appearancePreference = "system"
    @AppStorage("interfaceAnimations") private var interfaceAnimations = true
    @AppStorage("capacityWarningThreshold") private var warningThreshold = 20.0
    @AppStorage("capacityCriticalThreshold") private var criticalThreshold = 10.0

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearancePreference) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Animate value changes", isOn: $interfaceAnimations)
                Text("Animations also respect Reduce Motion in macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capacity thresholds") {
                LabeledContent("Warning") {
                    Text("\(warningThreshold, specifier: "%.0f")% free")
                }
                Slider(value: $warningThreshold, in: 10...40, step: 1)
                    .accessibilityLabel("Warning threshold")
                    .accessibilityValue("\(warningThreshold.formatted(.number.precision(.fractionLength(0)))) percent free")
                    .accessibilityHint("Adjusts the free-space percentage that produces a warning")
                    .onChange(of: warningThreshold) { _, value in
                        criticalThreshold = min(criticalThreshold, value)
                    }

                LabeledContent("Critical") {
                    Text("\(criticalThreshold, specifier: "%.0f")% free")
                }
                Slider(value: $criticalThreshold, in: 2...20, step: 1)
                    .accessibilityLabel("Critical threshold")
                    .accessibilityValue("\(criticalThreshold.formatted(.number.precision(.fractionLength(0)))) percent free")
                    .accessibilityHint("Adjusts the free-space percentage that produces a critical alert")
                    .onChange(of: criticalThreshold) { _, value in
                        warningThreshold = max(warningThreshold, value)
                    }
            }

            Section("Collection") {
                LabeledContent("APFS and block I/O", value: "Enabled")
                LabeledContent("NFS client statistics", value: "Enabled")
                LabeledContent("File-system quota", value: "Read only")
                LabeledContent("Benchmark", value: "Manual · 128 MiB maximum used")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 500, height: 560)
    }
}
