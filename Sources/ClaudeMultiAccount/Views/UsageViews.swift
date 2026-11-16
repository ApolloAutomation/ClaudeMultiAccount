import SwiftUI

/// Plan usage section: two glass gauges (5-hour, weekly).
struct PlanUsageSection: View {
    var usage: PlanUsageInfo
    var whoRecords: String

    var body: some View {
        Section {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    UsageGauge(title: "5-hour window", percent: usage.fiveHour)
                    UsageGauge(title: "Weekly", percent: usage.weekly)
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Plan Usage")
                Spacer()
                if let updated = usage.updatedAt {
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Claude saves a usage reading roughly every 15 minutes while \(whoRecords) is open. Reset times aren't recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct UsageGauge: View {
    var title: String
    var percent: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(levelColor ?? .primary)
            }
            Gauge(value: min(max(percent ?? 0, 0), 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(levelColor ?? .accentColor)
            if let level {
                Text(level == .critical ? "Almost at the limit" : "Getting close to the limit")
                    .font(.caption)
                    .foregroundStyle(levelColor ?? .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(percent.map { "\(Int($0)) percent" } ?? "Unknown")
    }

    private var level: UsageLevel? {
        guard let percent else { return nil }
        let level = UsageLevel(percent: percent)
        return level == .normal ? nil : level
    }

    private var levelColor: Color? {
        switch level {
        case .critical: .red
        case .warning: .orange
        default: nil
        }
    }
}

/// Compact text used in menus and sidebars.
func usageSummary(_ usage: PlanUsageInfo?) -> String? {
    guard let usage, usage.fiveHour != nil || usage.weekly != nil else { return nil }
    let five = usage.fiveHour.map { "\(Int($0.rounded()))%" } ?? "—"
    let week = usage.weekly.map { "\(Int($0.rounded()))%" } ?? "—"
    return "5h \(five) · week \(week)"
}
