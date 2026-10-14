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

/// The Bars style: a spend bar, then one bar per provider in a pastel of its brand color,
/// filled to the share its tightest limit shows (left or used, following the global setting), with the
/// provider's name on the fill and the number on the track. Hovering tells which limit it is
/// and when it resets; clicking opens every limit underneath, drawn the same way (`ProviderBarDetail`).
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
        VStack(alignment: .leading, spacing: 5) {
            if showTotalSpend, layout.hasSpendCapableProvider {
                SpendBar()
                    .padding(.bottom, 4)
            }
            ForEach(layout.displayGroups) { group in
                VStack(alignment: .leading, spacing: 4) {
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
                        ProviderBarDetail(group: group)
                            .padding(.bottom, 4)
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

/// One provider as a bar: a flat pastel fill on a quiet track, the mark and name in thin
/// monospaced capitals, the number at the end. Text that crosses the fill's edge changes
/// color with it, so it reads on both sides.
struct ProviderBar: View {
    let provider: Provider
    let reading: WidgetData?
    let notice: String?
    let isExpanded: Bool
    @State private var isHovering = false
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.locale) private var locale

    static let height: CGFloat = 30
    static let radius: CGFloat = 7

    private var fill: Color { BarPalette.pastel(provider.id, scheme: scheme) }

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
            let width = proxy.size.width * fraction
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(isHovering || isExpanded ? 0.09 : 0.055))
                Rectangle().fill(fill).frame(width: width)
                label(color: BarInk(fill.resolve(in: environment)).text)
                    .mask(alignment: .leading) { Rectangle().frame(width: width) }
                label(color: .primary)
                    .mask(alignment: .leading) {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: width)
                            Rectangle()
                        }
                    }
            }
        }
        .frame(height: Self.height)
        .clipShape(.rect(cornerRadius: Self.radius))
        .contentShape(.rect(cornerRadius: Self.radius))
        .onHover { isHovering = $0 }
        .help(help)
        .animation(Motion.spring, value: fraction)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func label(color: Color) -> some View {
        HStack(spacing: 8) {
            Group {
                if let mark = ProviderMarks.mark(for: provider.id) {
                    ProviderIconShape(mark: mark, inset: 0.04).fill(color)
                } else {
                    Image(systemName: ProviderMarks.symbolFallback(for: provider.id))
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(color)
                }
            }
            .frame(width: 13, height: 13)
            Text(provider.displayName.uppercased())
                .font(BarPalette.label)
                .tracking(0.8)
                .lineLimit(1)
            Spacer(minLength: 6)
            if notice != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
            }
            Text(value)
                .font(BarPalette.value)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }
}

/// The Bars style's look: soft pastels of each provider's brand color, flat, and thin
/// uppercase monospaced type.
enum BarPalette {
    static let label = Font.system(size: 11, weight: .light, design: .monospaced)
    static let value = Font.system(size: 12, weight: .regular, design: .monospaced)
    /// A bar's detail (`BarDetailContent`): a metric's name, its reading, and the small print.
    static let detailLabel = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let detailValue = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let detailNote = Font.system(size: 9.5, weight: .regular, design: .monospaced)

    /// The brand color, mostly white: pastel in light mode, a touch deeper in dark mode so
    /// it doesn't glare. Brands without a hue (black or white marks, like Cursor's) get a
    /// soft gray instead, which sits with the pastels in either mode.
    static func pastel(_ providerID: String, scheme: ColorScheme) -> Color {
        let brand = TotalSpendPalette.color(for: providerID)
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let resolved = brand.resolve(in: environment)
        let channels = [resolved.red, resolved.green, resolved.blue]
        if (channels.max() ?? 0) - (channels.min() ?? 0) < 0.08 {
            return Color(white: scheme == .dark ? 0.6 : 0.82)
        }
        return brand.mix(with: .white, by: scheme == .dark ? 0.42 : 0.58)
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(period.rawValue.uppercased())
                    .font(BarPalette.label)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text((projection.isEstimated ? "~" : "") + MetricFormatter.number(projection.centerValue, kind: .dollars, style: .full))
                    .font(BarPalette.value)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(projection.slices) { slice in
                        Rectangle()
                            .fill(BarPalette.pastel(slice.provider.id, scheme: scheme))
                            .frame(width: projection.centerValue > 0 ? proxy.size.width * slice.displayAmount / projection.centerValue : 0)
                    }
                }
            }
            .frame(height: 3)
        }
        .frame(height: ProviderBar.height)
        .background(Color.primary.opacity(0.055))
        .clipShape(.rect(cornerRadius: ProviderBar.radius))
        .contentShape(.rect(cornerRadius: ProviderBar.radius))
        .help(help)
    }

    private var help: String {
        let lines = projection.slices.map { "\($0.provider.displayName): \(MetricFormatter.number($0.displayAmount, kind: .dollars, style: .full))" }
        return ([period.rawValue] + (lines.isEmpty ? ["Nothing spent"] : lines) + ["Click for another period"]).joined(separator: "\n")
    }
}

/// The text on a pastel fill: dark, unless a fill turns out deep enough to need white.
private struct BarInk {
    let luminance: Float

    init(_ color: Color.Resolved) {
        luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    var text: Color { luminance > 0.45 ? Color(white: 0.16) : .white }
}
