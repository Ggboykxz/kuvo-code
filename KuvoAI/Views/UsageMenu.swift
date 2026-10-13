import OpenCodeKit
import SwiftUI

/// The menu bar item: a gauge and the least that's left across your plans.
struct UsageMenuLabel: View {
    @Environment(UsageStore.self) private var usage

    var body: some View {
        if let tightest = usage.tightest {
            Label(tightest.remaining.formatted(.percent.precision(.fractionLength(0))), systemImage: symbol(tightest.remaining))
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }

    private func symbol(_ remaining: Double) -> String {
        switch remaining {
        case ..<0.2: "gauge.with.dots.needle.100percent"
        case ..<0.5: "gauge.with.dots.needle.67percent"
        case ..<0.8: "gauge.with.dots.needle.33percent"
        default: "gauge.with.dots.needle.0percent"
        }
    }
}

/// The menu bar panel: each connected plan, one bar per limit, and when it resets.
struct UsageMenu: View {
    @Environment(UsageStore.self) private var usage
    @Environment(Catalog.self) private var catalog
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage")
                    .font(.headline)
                Spacer()
                if let updated = usage.updated {
                    Text(updated, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await usage.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(usage.isRefreshing ? 360 : 0))
                        .animation(usage.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: usage.isRefreshing)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            if usage.reports.isEmpty {
                Text(usage.updated == nil ? "Checking your plans…" : "Sign in to Codex or Claude Code, or connect GitHub Copilot or OpenCode Go, to see how much of your plan is left.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(usage.reports) { report in
                    PlanUsage(report: report)
                    if report.id != usage.reports.last?.id { Divider() }
                }
            }

            Divider()
            HStack {
                Button("Open \(AppInfo.name)") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Settings…") {
                    UserDefaults.standard.set("usage", forKey: "settings.tab")
                    openSettings()
                    NSApp.activate()
                }
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .frame(width: 320)
        .task { await usage.refresh() }
    }
}

private struct PlanUsage: View {
    let report: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderLogo(id: report.logo, size: 16)
                Text(report.name)
                    .font(.body.weight(.semibold))
                if let plan = report.plan {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: .capsule)
                }
            }
            ForEach(report.meters) { meter in
                MeterRow(meter: meter)
            }
            ForEach(report.facts) { fact in
                HStack {
                    Text(fact.label)
                    Spacer()
                    Text(fact.value)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let note = report.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MeterRow: View {
    let meter: UsageMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label)
                    .font(.callout)
                Spacer()
                Text("\(meter.remaining.formatted(.percent.precision(.fractionLength(0)))) left")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    // Plain text reads on any panel; colour only when it's a warning.
                    .foregroundStyle(meter.remaining < 0.3 ? AnyShapeStyle(color) : AnyShapeStyle(.primary))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // A track you can see on the menu bar's glass, with a hairline edge.
                    Capsule()
                        .fill(Color.primary.opacity(0.16))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    // Fills with what's left, so it drains as you use the plan, like the label says.
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(proxy.size.width * meter.remaining, meter.remaining > 0 ? 4 : 0))
                }
            }
            .frame(height: 8)
            HStack {
                if let detail = meter.detail { Text(detail) }
                Spacer()
                if let resets = meter.resetsAt { Text(resetText(resets)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch meter.remaining {
        case ..<0.1: .red
        case ..<0.3: .orange
        default: .accentColor
        }
    }

    /// "Resets in 2 hr, 14 min" when soon, "Resets Nov 1" when not.
    private func resetText(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "Resetting now" }
        if interval < 24 * 3600 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = interval < 3600 ? [.minute] : [.hour, .minute]
            formatter.unitsStyle = .short
            return "Resets in " + (formatter.string(from: interval) ?? "")
        }
        return "Resets " + date.formatted(.dateTime.month(.abbreviated).day())
    }
}
