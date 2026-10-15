import OpenCodeKit
import SwiftUI

/// Effort levels as people say them: "xhigh" is Extra.
enum EffortLevel {
    static func title(_ id: String) -> String {
        switch id.lowercased() {
        case "xhigh", "x-high", "extra-high", "extra_high", "extrahigh": "Extra"
        case "max", "maximum": "Max"
        case "none", "off": "Off"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

/// The model and its effort, in a card that stays open while you choose both: pick a model and
/// its levels show below, right away. The short list first (1–9 pick one), every model by
/// provider a click away, and typing searches them all. ↑ ↓ move through the list, ← → change the
/// effort, Return or a click outside closes it.
struct ModelPicker: View {
    let catalog: Catalog
    let selection: ModelRef?
    let onSelect: (ModelRef) -> Void
    let close: () -> Void
    var startsExpanded = false
    @AppStorage("recentModels") private var recentStorage = ""
    /// What you just picked, shown before the session catches up.
    @State private var picked: ModelRef?
    @State private var query = ""
    @State private var expanded = false
    /// The row under the pointer or the arrow keys.
    @State private var highlight: String?
    @FocusState private var focus: Focus?

    private enum Focus { case list, search }

    private var choice: ModelRef? { picked ?? selection }
    private var current: Model? { catalog.model(choice) ?? catalog.defaultModel }
    private var variant: String? { current.flatMap { model in choice?.sameModel(as: model.ref) == true ? choice?.variant : nil } }

    /// The rows in order, as the arrow keys go through them: an ID of their own (a model can show
    /// in the short list and under its provider), and the model.
    private var rows: [(id: String, model: Model)] {
        if !query.isEmpty { return results.map { ("found-\($0.key)", $0) } }
        var rows = shortList.map { ("short-\($0.key)", $0) }
        if expanded { rows += catalog.modelsByProvider.flatMap { group in group.models.map { ("all-\($0.key)", $0) } } }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.6)
            list
            if let current, !current.variants.isEmpty {
                Divider().opacity(0.6)
                EffortSlider(levels: current.variants.map(\.id), selected: variant) { level in
                    choose(ModelRef(id: current.id, providerID: current.providerID, variant: level))
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            if let current {
                HStack {
                    Text("Context window")
                    Spacer()
                    Text(current.limit.context.compactTokens)
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .padding(.top, current.variants.isEmpty ? 10 : 0)
            }
        }
        .frame(width: 320)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .list)
        .onKeyPress(phases: .down, action: key)
        .onAppear {
            expanded = startsExpanded
            focus = .list
        }
        .onChange(of: selection) { picked = nil }
    }

    // MARK: Parts

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: .search)
                .onKeyPress(phases: .down, action: key)
                .onSubmit { pickHighlighted(closing: true) }
            if !query.isEmpty {
                Button {
                    query = ""
                    focus = .list
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .onChange(of: query) { highlight = rows.first?.id }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if query.isEmpty {
                        ForEach(Array(shortList.enumerated()), id: \.element.key) { index, model in
                            row(model, id: "short-\(model.key)", number: index < 9 ? index + 1 : nil)
                        }
                        if !catalog.modelsByProvider.isEmpty {
                            allModelsToggle
                        }
                        if expanded {
                            ForEach(catalog.modelsByProvider, id: \.provider) { group in
                                providerHeader(group.provider, logo: group.models.first?.providerID ?? "", count: group.models.count)
                                ForEach(group.models, id: \.key) { model in
                                    row(model, id: "all-\(model.key)", number: nil)
                                }
                            }
                        }
                    } else if results.isEmpty {
                        Text("No models match “\(query)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(results, id: \.key) { model in
                            row(model, id: "found-\(model.key)", number: nil)
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: expanded || !query.isEmpty ? 380 : nil)
            .fixedSize(horizontal: false, vertical: !(expanded || !query.isEmpty))
            .onChange(of: highlight) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ model: Model, id: String, number: Int?) -> some View {
        let isCurrent = model.ref.sameModel(as: current?.ref)
        // "Free" only for OpenCode Zen's free models; a $0 subscription model isn't free.
        let free = model.providerID == "opencode" && model.isFree
        let detail = free ? catalog.providerName(model.providerID) + " · Free" : catalog.providerName(model.providerID)
        return Button {
            pick(model)
        } label: {
            HStack(spacing: 10) {
                ProviderLogo(id: model.makerLogoID, size: 16)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(size: 13, weight: isCurrent ? .medium : .regular))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                } else if let number {
                    Text("\(number)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(highlight == id ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight = id } }
        .id(id)
    }

    private var allModelsToggle: some View {
        Button {
            withAnimation(.ui) { expanded.toggle() }
        } label: {
            HStack {
                Text("All Models")
                    .font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(highlight == "all" ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight = "all" } }
        .padding(.top, 4)
    }

    private func providerHeader(_ name: String, logo: String, count: Int) -> some View {
        HStack(spacing: 6) {
            ProviderLogo(id: logo, size: 12)
            Text(name)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    // MARK: Choosing

    /// A model, keeping the effort you had if it has that level too. The card stays open: you'll
    /// often set the effort next.
    private func pick(_ model: Model) {
        let keep = variant.flatMap { level in model.variants.contains { $0.id == level } ? level : nil }
        remember(model)
        choose(ModelRef(id: model.id, providerID: model.providerID, variant: keep))
    }

    private func choose(_ ref: ModelRef) {
        picked = ref
        onSelect(ref)
    }

    private func pickHighlighted(closing: Bool) {
        if let id = highlight, let row = rows.first(where: { $0.id == id }) {
            pick(row.model)
        } else if highlight == nil, !query.isEmpty, let first = results.first {
            pick(first)
        }
        if closing { close() }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            close()
            return .handled
        case .return:
            pickHighlighted(closing: true)
            return .handled
        case .downArrow, .upArrow:
            let ids = rows.map(\.id)
            guard !ids.isEmpty else { return .handled }
            let at = highlight.flatMap { ids.firstIndex(of: $0) }
            let next = press.key == .downArrow ? (at.map { min($0 + 1, ids.count - 1) } ?? 0) : (at.map { max($0 - 1, 0) } ?? ids.count - 1)
            highlight = ids[next]
            return .handled
        case .leftArrow, .rightArrow:
            // While typing, the arrows move in the text.
            guard focus != .search, let current, !current.variants.isEmpty else { return .ignored }
            let levels = current.variants.map(\.id)
            let at = variant.flatMap { levels.firstIndex(of: $0) }
            let next = press.key == .rightArrow ? (at.map { min($0 + 1, levels.count - 1) } ?? 0) : (at.map { $0 - 1 } ?? -1)
            choose(ModelRef(id: current.id, providerID: current.providerID, variant: next >= 0 ? levels[next] : nil))
            return .handled
        default:
            break
        }
        guard focus != .search, press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        // 1–9 pick from the short list; anything else starts a search.
        if query.isEmpty, let digit = Int(press.characters), (1...9).contains(digit) {
            let models = shortList
            if models.indices.contains(digit - 1) { pick(models[digit - 1]) }
            return .handled
        }
        guard let character = press.characters.first, character.isLetter || character.isNumber || character == "-" || character == "." else { return .ignored }
        query += press.characters
        focus = .search
        return .handled
    }

    // MARK: Lists

    /// Every model that matches what you typed, by provider as in All Models.
    private var results: [Model] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return catalog.modelsByProvider.flatMap(\.models).filter { model in
            let text = "\(model.name) \(model.id) \(model.family ?? "") \(catalog.providerName(model.providerID))".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        .prefix(80)
        .map { $0 }
    }

    /// The current model, then recently used ones, then the newest model of each family (Claude
    /// Opus, GPT Sol, Gemini Flash, …) from each provider, accounts you connected before the free
    /// OpenCode Zen models.
    private var shortList: [Model] {
        let enabled = catalog.models.filter(\.enabled)
        let recent = recentStorage.split(separator: ",").compactMap { key in enabled.first { $0.key == key } }
        var newestByFamily: [String: Model] = [:]
        for model in enabled {
            let family = model.providerID + "/" + (model.family ?? model.id)
            if let existing = newestByFamily[family], existing.time.released >= model.time.released { continue }
            newestByFamily[family] = model
        }
        let perProvider = Dictionary(grouping: newestByFamily.values, by: \.providerID)
            .mapValues { Array($0.sorted { $0.time.released > $1.time.released }.prefix(4)) }
        let providers = perProvider.keys.sorted { lhs, rhs in
            // Free models last: someone who connected an account wants its models first.
            (lhs == "opencode" ? 1 : 0, Catalog.featuredOrder[lhs] ?? 99, lhs) < (rhs == "opencode" ? 1 : 0, Catalog.featuredOrder[rhs] ?? 99, rhs)
        }
        var seen = Set<String>()
        // The model in use leads only when the card opens; picking another doesn't reorder the list
        // under the pointer.
        let leading = catalog.model(selection) ?? catalog.defaultModel
        let candidates = [leading].compactMap(\.self) + recent + providers.flatMap { perProvider[$0] ?? [] }
        return candidates.filter { seen.insert($0.key).inserted }.prefix(10).map { $0 }
    }

    private func remember(_ model: Model) {
        var keys = recentStorage.split(separator: ",").map(String.init).filter { $0 != model.key }
        keys.insert(model.key, at: 0)
        recentStorage = keys.prefix(4).joined(separator: ",")
    }
}

/// Effort as a slider with a stop for each level, the level above it in the accent color, and a
/// way back to the model's own default.
struct EffortSlider: View {
    let levels: [String]
    /// nil for the model's default.
    let selected: String?
    let onSelect: (String?) -> Void

    private var index: Int? { selected.flatMap { levels.firstIndex(of: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("Effort")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                // The value stays at the right edge; back to the default only once there's a level.
                if selected != nil {
                    Button {
                        onSelect(nil)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Back to the model's default")
                    .transition(.opacity)
                }
                Text(selected.map(EffortLevel.title) ?? "Default")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .contentTransition(.numericText())
            }
            track
            HStack {
                Text(levels.first.map(EffortLevel.title) ?? "")
                Spacer()
                Text("Thinks longer, uses more of your limits")
                    .opacity(levels.count > 2 ? 1 : 0)
                Spacer()
                Text(levels.last.map(EffortLevel.title) ?? "")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .animation(.snappy(duration: 0.2), value: selected)
    }

    private var track: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 12
            let room = max(geometry.size.width - inset * 2, 1)
            let x = { (i: Int) -> CGFloat in inset + (levels.count > 1 ? room * CGFloat(i) / CGFloat(levels.count - 1) : room / 2) }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                if let index {
                    Capsule()
                        .fill(.tint)
                        .frame(width: x(index) + inset)
                }
                ForEach(levels.indices, id: \.self) { i in
                    Circle()
                        .fill(index.map { i <= $0 } == true ? Color.white.opacity(0.75) : Color.primary.opacity(0.25))
                        .frame(width: 5, height: 5)
                        .position(x: x(i), y: geometry.size.height / 2)
                }
                if let index {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: 20, height: 20)
                        .position(x: x(index), y: geometry.size.height / 2)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let i = Int(((value.location.x - inset) / room * CGFloat(max(levels.count - 1, 1))).rounded())
                        let level = levels[min(max(i, 0), levels.count - 1)]
                        if level != selected { onSelect(level) }
                    }
            )
        }
        .frame(height: 24)
        .help(levels.map(EffortLevel.title).joined(separator: ", "))
    }
}
