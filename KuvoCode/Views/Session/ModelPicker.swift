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

/// The model's effort, and the model, in one card that stays open, as Codex does: it opens on the
/// effort, a slider, under the level and the model, which open the model list. Picking a model
/// there turns back to its effort (a model without levels closes the card). **More models** has
/// every model by provider, and typing searches them. What you chose goes to the session as the
/// card closes, once.
struct ModelPicker: View {
    let catalog: Catalog
    let selection: ModelRef?
    let onSelect: (ModelRef) -> Void
    let close: () -> Void
    var startsExpanded = false
    /// On the model list rather than the effort (KUVO_DEMO_MENU=list).
    var startsOnList = false
    @AppStorage("recentModels") private var recentStorage = ""
    /// What you've picked, until the card closes.
    @State private var picked: ModelRef?
    @State private var page = Page.models
    @State private var query = ""
    /// The row under the pointer or the arrow keys.
    @State private var highlight: String?
    @FocusState private var focus: Focus?

    private enum Page { case models, all, effort }
    private enum Focus { case card, search }

    private var choice: ModelRef? { picked ?? selection }
    private var current: Model? { catalog.model(choice) ?? catalog.defaultModel }
    private var variant: String? { current.flatMap { model in choice?.sameModel(as: model.ref) == true ? choice?.variant : nil } }

    var body: some View {
        Group {
            switch page {
            case .models: modelsPage
            case .all: allModelsPage
            case .effort: effortPage
            }
        }
        .frame(width: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .card)
        .onKeyPress(phases: .down, action: key)
        .onAppear {
            // The effort first, for a model that has levels; else the list.
            page = startsExpanded ? .all : (startsOnList || current?.variants.isEmpty != false ? .models : .effort)
            focus = .card
            highlight = shortList.first { $0.ref.sameModel(as: current?.ref) }.map { row($0) }
        }
        .onDisappear {
            if let picked, !(picked.sameModel(as: selection) && picked.variant == selection?.variant) { onSelect(picked) }
        }
    }

    // MARK: Models

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select model")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            VStack(spacing: 1) {
                let list = shortList
                ForEach(list, id: \.key) { model in
                    // The provider only where it tells two of the same model apart.
                    modelRow(model, showsProvider: list.filter { $0.name == model.name }.count > 1)
                }
            }
            .padding(.horizontal, 6)
            if !catalog.modelsByProvider.isEmpty {
                Divider()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                navigationRow("More models", id: "more") { go(.all) }
                    .padding(.horizontal, 6)
            }
            Spacer().frame(height: 6)
        }
    }

    private var allModelsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { go(.models) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back")
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focus, equals: .search)
                    .onKeyPress(phases: .down, action: key)
                    .onSubmit { pickHighlighted() }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if query.isEmpty {
                            ForEach(catalog.modelsByProvider, id: \.provider) { group in
                                Text(group.provider)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 3)
                                ForEach(group.models, id: \.key) { model in
                                    modelRow(model, showsProvider: false)
                                }
                            }
                        } else if results.isEmpty {
                            Text("No models match “\(query)”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        } else {
                            ForEach(results, id: \.key) { model in
                                modelRow(model)
                            }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(height: 360)
                .onChange(of: highlight) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
        .onChange(of: query) { highlight = results.first.map { row($0) } }
    }

    private func modelRow(_ model: Model, showsProvider: Bool = true) -> some View {
        let id = row(model)
        let isCurrent = model.ref.sameModel(as: current?.ref)
        // "Free" only for OpenCode Zen's free models; a $0 subscription model isn't free.
        let free = model.providerID == "opencode" && model.isFree
        let detail = showsProvider ? catalog.providerName(model.providerID) : (free && !model.name.localizedCaseInsensitiveContains("free") ? "Free" : "")
        return Button {
            pick(model)
        } label: {
            HStack(spacing: 9) {
                ProviderLogo(id: model.makerLogoID, size: 15)
                    .frame(width: 18)
                Text(model.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(isCurrent ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(highlight == id ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight = id } }
        .id(id)
    }

    private func navigationRow(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 14))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(highlight == id ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight = id } }
    }

    // MARK: Effort

    private var effortPage: some View {
        VStack(spacing: 14) {
            ZStack {
                // The level and the model, and only they, open the model list.
                Button { go(.models) } label: {
                    VStack(spacing: 2) {
                        Text(variant.map(EffortLevel.title) ?? "Default")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(variant == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                        HStack(spacing: 3) {
                            Text(current?.name ?? "")
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .hoverHighlight(in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .help("Choose another model")
                // Room for the logo and the reset button beside it, outside what opens the list.
                .padding(.horizontal, 32)
                // Beside it, without moving it: who made the model, and back to its default.
                HStack {
                    if let current {
                        ProviderLogo(id: current.makerLogoID, size: 24, colored: true)
                            .frame(width: 30, height: 30)
                            .allowsHitTesting(false)
                    }
                    Spacer()
                    Button { pickEffort(nil) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 26, height: 26)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(variant == nil ? 0 : 1)
                    .disabled(variant == nil)
                    .help("Back to the model's default effort")
                }
                .padding(.horizontal, 8)
            }
            if let current {
                EffortSlider(levels: current.variants.map(\.id), selected: variant) { pickEffort($0) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    // MARK: Choosing

    private func go(_ next: Page) {
        withAnimation(.snappy(duration: 0.2)) { page = next }
        if next == .all {
            focus = .search
        } else {
            query = ""
            focus = .card
        }
        highlight = nil
    }

    /// A model, keeping the effort you had if it has that level too; then its effort, or, for a
    /// model without levels, the card closes.
    private func pick(_ model: Model) {
        let keep = variant.flatMap { level in model.variants.contains { $0.id == level } ? level : nil }
        remember(model)
        picked = ModelRef(id: model.id, providerID: model.providerID, variant: keep)
        if model.variants.isEmpty {
            close()
        } else {
            go(.effort)
        }
    }

    private func pickEffort(_ level: String?) {
        guard let current else { return }
        picked = ModelRef(id: current.id, providerID: current.providerID, variant: level)
    }

    private func pickHighlighted() {
        let models = page == .models ? shortList : (query.isEmpty ? catalog.modelsByProvider.flatMap(\.models) : results)
        if let model = models.first(where: { row($0) == highlight }) ?? (page == .all && !query.isEmpty ? results.first : nil) {
            pick(model)
        } else if highlight == "more" {
            go(.all)
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            close()
            return .handled
        case .return:
            if page == .effort { close() } else { pickHighlighted() }
            return .handled
        case .downArrow, .upArrow:
            guard page != .effort else { return .ignored }
            var ids = (page == .models ? shortList : (query.isEmpty ? catalog.modelsByProvider.flatMap(\.models) : results)).map(row)
            if page == .models, !catalog.modelsByProvider.isEmpty { ids.append("more") }
            guard !ids.isEmpty else { return .handled }
            let at = highlight.flatMap { ids.firstIndex(of: $0) }
            let next = press.key == .downArrow ? (at.map { min($0 + 1, ids.count - 1) } ?? 0) : (at.map { max($0 - 1, 0) } ?? ids.count - 1)
            highlight = ids[next]
            return .handled
        case .leftArrow, .rightArrow:
            guard page == .effort, let current, !current.variants.isEmpty else { return .ignored }
            let levels = current.variants.map(\.id)
            let at = variant.flatMap { levels.firstIndex(of: $0) }
            let next = press.key == .rightArrow ? (at.map { min($0 + 1, levels.count - 1) } ?? 0) : (at.map { $0 - 1 } ?? -1)
            pickEffort(next >= 0 ? levels[next] : nil)
            return .handled
        default:
            break
        }
        // Typing on the list searches every model.
        guard page == .models, press.modifiers.isEmpty || press.modifiers == .shift,
              let character = press.characters.first, character.isLetter || character.isNumber else { return .ignored }
        query = press.characters
        go(.all)
        return .handled
    }

    // MARK: Lists

    private func row(_ model: Model) -> String { model.key }

    /// Every model that matches what you typed, by provider as in More Models.
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
        // The model in use leads as the card opens; picking another doesn't reorder the list.
        let leading = catalog.model(selection) ?? catalog.defaultModel
        let candidates = [leading].compactMap(\.self) + recent + providers.flatMap { perProvider[$0] ?? [] }
        return candidates.filter { seen.insert($0.key).inserted }.prefix(8).map { $0 }
    }

    private func remember(_ model: Model) {
        var keys = recentStorage.split(separator: ",").map(String.init).filter { $0 != model.key }
        keys.insert(model.key, at: 0)
        recentStorage = keys.prefix(4).joined(separator: ",")
    }
}

/// Effort as a slider with a stop for each level, filled up to the one picked. While you drag, it
/// follows the pointer as it is; a click or a key glides to the level.
struct EffortSlider: View {
    let levels: [String]
    /// nil for the model's default: nothing filled, no knob.
    let selected: String?
    let onSelect: (String?) -> Void
    @State private var dragging = false

    private var index: Int? { selected.flatMap { levels.firstIndex(of: $0) } }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let inset = height / 2
            let room = max(geometry.size.width - inset * 2, 1)
            let x = { (i: Int) -> CGFloat in inset + (levels.count > 1 ? room * CGFloat(i) / CGFloat(levels.count - 1) : room / 2) }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(.tint)
                    .frame(width: index.map { x($0) + inset } ?? 0)
                    .opacity(index == nil ? 0 : 1)
                ForEach(levels.indices, id: \.self) { i in
                    Circle()
                        .fill(index.map { i < $0 } == true ? Color.white.opacity(0.6) : Color.primary.opacity(0.25))
                        .frame(width: 5, height: 5)
                        .position(x: x(i), y: height / 2)
                        .opacity(index == i ? 0 : 1)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .frame(width: height + 4, height: height + 4)
                    .position(x: x(index ?? 0), y: height / 2)
                    .opacity(index == nil ? 0 : 1)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let i = Int(((value.location.x - inset) / room * CGFloat(max(levels.count - 1, 1))).rounded())
                        let level = levels[min(max(i, 0), levels.count - 1)]
                        if level != selected { onSelect(level) }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 26)
        .animation(dragging ? nil : .snappy(duration: 0.18), value: selected)
        .help(levels.map(EffortLevel.title).joined(separator: ", "))
    }
}
