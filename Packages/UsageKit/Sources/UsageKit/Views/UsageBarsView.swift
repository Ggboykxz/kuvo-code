import AppKit
import SwiftUI

/// How the dashboard lists providers: one compact bar each, or the full cards.
enum DashboardStyle: String, Hashable, Sendable, CaseIterable {
    case bars
    case cards

    static let key = "dashboardStyle"

    var label: String {
        switch self {
        case .bars: "Bars"
        case .cards: "Cards"
        }
    }
}

/// Which of a provider's limits its bar shows.
enum BarMetricSetting: String, Hashable, Sendable, CaseIterable {
    /// The limit with the least left: the one that stops you first.
    case tightest
    /// The first limit in the provider's card, in the order Customize sets.
    case first

    static let key = "barMetric"

    var label: String {
        switch self {
        case .tightest: "Closest to Its Limit"
        case .first: "First in Its Card"
        }
    }
}

/// The Bars style: a spend bar, then one bar per provider in its brand color, filled to the
/// share its tightest limit shows (left or used, following the global setting), with the
/// provider's name on the fill and the number on the track. Hovering tells which limit it is
/// and when it resets; clicking opens the provider's full card underneath.
struct UsageBarsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(BarMetricSetting.key) private var barMetric = BarMetricSetting.tightest
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    /// The provider whose full card is open under its bar.
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showTotalSpend, layout.hasSpendCapableProvider {
                SpendBar()
                    .padding(.bottom, 4)
            }
            ForEach(layout.displayGroups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    ProviderBar(
                        provider: group.provider,
                        reading: reading(for: group),
                        notice: dataStore.headerNotice(for: group.provider.id),
                        isExpanded: expanded == group.id
                    )
                    .onTapGesture {
                        withAnimation(Motion.spring) { expanded = expanded == group.id ? nil : group.id }
                    }
                    .contextMenu { menu(for: group) }
                    if expanded == group.id {
                        WidgetGroupedListView(reorderSpaceName: reorderSpaceName, reorderLift: $reorderLift, onlyProviderID: group.id)
                            .padding(.bottom, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.spring, value: layout.displayGroups.map(\.provider.id))
    }

    /// The limit the bar shows, or the provider's first reading of any kind when it has no
    /// limits (a balance, say).
    private func reading(for group: ProviderGroup) -> WidgetData? {
        let rows = group.widgets.compactMap(layout.descriptor(for:)).map(dataStore.data(for:)).filter { $0.hasData && !$0.isChart }
        let meters = rows.filter(\.isBounded)
        switch barMetric {
        case .first:
            return meters.first ?? rows.first
        case .tightest:
            return meters.min { $0.remainingFraction < $1.remainingFraction } ?? rows.first
        }
    }

    @ViewBuilder
    private func menu(for group: ProviderGroup) -> some View {
        Button("Hide \(group.provider.displayName)") {
            container.enablement.setEnabled(false, for: group.provider.id)
        }
        Divider()
        Button("Refresh \(group.provider.displayName)") {
            Task { await dataStore.refreshOnUserRequest(providerID: group.provider.id) }
        }
        Button("Customize…") {
            withAnimation(Motion.modeSwitch) {
                layout.customizeProviderID = group.provider.id
                layout.isEditing = true
            }
        }
    }
}

/// One provider as a bar, after the Figma sketch: brand-colored fill, a darker track, the mark
/// and name in condensed capitals, the number at the end. Text that crosses the fill's edge
/// changes color with it, so it reads on both sides.
struct ProviderBar: View {
    let provider: Provider
    let reading: WidgetData?
    let notice: String?
    let isExpanded: Bool
    @State private var isHovering = false
    @Environment(\.self) private var environment
    @Environment(\.locale) private var locale

    static let height: CGFloat = 34

    private var brand: Color { TotalSpendPalette.color(for: provider.id) }

    private var fraction: Double {
        guard let reading, reading.isBounded else { return 0 }
        return reading.fraction
    }

    private var value: String {
        guard let reading else { return WidgetData.noDataHeadline }
        guard reading.isBounded else { return reading.menuBarValue }
        if reading.kind == .percent {
            return fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        }
        return reading.menuBarValue
    }

    private var help: String {
        var lines = [provider.displayName]
        if let reading {
            lines.append("\(reading.title): \(reading.isBounded ? reading.boundedHeadline : reading.valueText)")
            if let subtitle = reading.boundedSubtitle { lines.append(subtitle) }
        } else {
            lines.append("No data yet")
        }
        if let notice { lines.append(notice) }
        lines.append(isExpanded ? "Click to close" : "Click for every limit")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        GeometryReader { proxy in
            let fill = proxy.size.width * fraction
            let ink = BarInk(brand.resolve(in: environment))
            ZStack(alignment: .leading) {
                Rectangle().fill(ink.isDark ? brand.mix(with: .white, by: 0.32) : brand.mix(with: .black, by: 0.58))
                Rectangle().fill(brand.gradient).frame(width: fill)
                label(color: ink.text)
                    .mask(alignment: .leading) { Rectangle().frame(width: fill) }
                label(color: .white)
                    .mask(alignment: .leading) {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: fill)
                            Rectangle()
                        }
                    }
            }
        }
        .frame(height: Self.height)
        .clipShape(.rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(isHovering || isExpanded ? 0.35 : 0), lineWidth: 1.5)
        }
        .contentShape(.rect(cornerRadius: 9))
        .onHover { isHovering = $0 }
        .help(help)
        .animation(Motion.spring, value: fraction)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func label(color: Color) -> some View {
        HStack(spacing: 8) {
            Group {
                if let mark = ProviderMarks.mark(for: provider.id) {
                    ProviderIconShape(mark: mark, inset: 0.02).fill(color)
                } else {
                    Image(systemName: ProviderMarks.symbolFallback(for: provider.id))
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(color)
                }
            }
            .frame(width: 16, height: 16)
            Text(provider.displayName.uppercased())
                .font(.system(size: 14, weight: .semibold).width(.condensed))
                .tracking(0.6)
                .lineLimit(1)
            Spacer(minLength: 6)
            if notice != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold).width(.condensed))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
    }
}

/// What the providers cost over a period, as one bar: the total, and each provider's share as
/// a strip of its color along the bottom. Clicking steps through Today, Yesterday and the last
/// 30 days.
private struct SpendBar: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(TotalSpendSetting.periodKey) private var periodRawValue = TotalSpendPeriod.today.rawValue

    private var period: TotalSpendPeriod { TotalSpendPeriod(rawValue: periodRawValue) ?? .today }

    private var projection: TotalSpendProjection {
        TotalSpendAggregator.total(for: period, providers: layout.spendCapableProviders, snapshots: dataStore.snapshots)
            .projection(for: .cost)
    }

    var body: some View {
        SpendBarBody(period: period, projection: projection)
            .onTapGesture {
                let all = TotalSpendPeriod.allCases
                let next = all[((all.firstIndex(of: period) ?? 0) + 1) % all.count]
                withAnimation(Motion.spring) { periodRawValue = next.rawValue }
            }
    }
}

/// The spend bar's drawing, apart from where its numbers come from.
struct SpendBarBody: View {
    let period: TotalSpendPeriod
    let projection: TotalSpendProjection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(period.rawValue.uppercased())
                    .font(.system(size: 14, weight: .semibold).width(.condensed))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text((projection.isEstimated ? "~" : "") + MetricFormatter.number(projection.centerValue, kind: .dollars, style: .full))
                    .font(.system(size: 16, weight: .semibold).width(.condensed))
                    .monospacedDigit()
            }
            .padding(.horizontal, 11)
            .frame(maxHeight: .infinity)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(projection.slices) { slice in
                        Rectangle()
                            .fill(TotalSpendPalette.color(for: slice.provider.id))
                            .frame(width: projection.centerValue > 0 ? proxy.size.width * slice.displayAmount / projection.centerValue : 0)
                    }
                }
            }
            .frame(height: 4)
        }
        .frame(height: ProviderBar.height)
        .background(Color.primary.opacity(0.07))
        .clipShape(.rect(cornerRadius: 9))
        .contentShape(.rect(cornerRadius: 9))
        .help(help)
    }

    private var help: String {
        let lines = projection.slices.map { "\($0.provider.displayName): \(MetricFormatter.number($0.displayAmount, kind: .dollars, style: .full))" }
        return ([period.rawValue] + (lines.isEmpty ? ["Nothing spent"] : lines) + ["Click for another period"]).joined(separator: "\n")
    }
}

/// How light a brand color is, as drawn: it picks the text on the fill (dark on light brands,
/// white on the rest) and which way the track goes (darker for most brands, lighter for the
/// near-black ones, so the fill still stands out).
private struct BarInk {
    let luminance: Float

    init(_ color: Color.Resolved) {
        luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    var isDark: Bool { luminance < 0.2 }
    var text: Color { luminance > 0.62 ? Color(white: 0.1) : .white }
}
