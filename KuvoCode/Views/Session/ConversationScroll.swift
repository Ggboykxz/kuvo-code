import AppKit
import SwiftUI

/// How a conversation scrolls, for the view showing it: whether it keeps to the end, and asking
/// it to go somewhere (back to the end, to a row Find found).
@Observable
final class ConversationScroller {
    enum Request: Equatable {
        case end(animated: Bool)
        case row(String)
        /// A place in a row, this far down it, in the middle (a place Find found).
        case place(String, CGFloat)
        /// A distance from the top, for the scrolling test.
        case offset(CGFloat)
    }

    /// Whether to keep the newest in view: true until you scroll up, true again once you scroll
    /// back to the end. Set only when it changes (`follow`): each setting draws the conversation again.
    var followsEnd = true
    /// All of it fits in view: nothing to scroll. (Not until it's known.)
    @ObservationIgnored fileprivate(set) var fits = false
    @ObservationIgnored fileprivate(set) var request: Request?
    /// Goes up with each request, for the scroll view to take it.
    fileprivate(set) var requests = 0

    /// To the end, following it again (you sent something).
    func toEnd(animated: Bool = false) {
        follow(true)
        ask(.end(animated: animated))
    }

    /// `id`'s row in the middle, and no following the end meanwhile.
    func reveal(_ id: String) {
        follow(false)
        ask(.row(id))
    }

    /// The place `fraction` of the way down `id`'s row in the middle, and no following the end
    /// meanwhile.
    func reveal(_ id: String, at fraction: CGFloat) {
        follow(false)
        ask(.place(id, min(max(fraction, 0), 1)))
    }

    func scroll(to offset: CGFloat) {
        follow(false)
        ask(.offset(offset))
    }

    fileprivate func follow(_ follows: Bool) {
        if followsEnd != follows { followsEnd = follows }
    }

    private func ask(_ request: Request) {
        self.request = request
        requests += 1
    }
}

/// A conversation's rows, a session's or a group chat's: made as they come into view, kept at the
/// end while new ones come in (until you scroll up, with a button back), softly blurred where they
/// go under the card's header and the composer, and with a menu over text you select to quote
/// or copy it.
struct ConversationScroll<Rows: View>: View {
    #if DEBUG
    private static var edgeStyle: ScrollEdgeEffectStyle? { Perf.noEdge ? nil : .soft }
    #else
    private static var edgeStyle: ScrollEdgeEffectStyle? { .soft }
    #endif

    let scroller: ConversationScroller
    var spacing: CGFloat = 0
    /// Rows changing animate with this (nil: not, as for a whole history arriving at once), when
    /// `change` does.
    var animation: Animation? = .ui
    let change: AnyHashable
    /// Thinking under way, if any: once it's done, it folds into its steps' summary, and its row
    /// gets much shorter.
    var thinking: Thinking? = nil
    /// Called as you scroll within a couple of screens of the top: earlier rows can come in
    /// then, above what you're reading, which stays where it is (see `ScrollAnchor`).
    var nearTop: (() -> Void)? = nil
    /// Text you selected, to answer in the composer.
    let quote: (String) -> Void
    @ViewBuilder let rows: Rows

    /// Scrolling now: a plain flag, so starting and stopping don't redraw the conversation.
    @State private var scrolling = ScrollingFlag()
    @State private var endFollower = EndFollower()
    @State private var spot = ScrollSpot()
    @State private var fold = FoldWatch()
    @State private var anchor = ScrollAnchor()

    var body: some View {
        // Scrolled by AppKit's scroll view (to the end, to a place, keeping what you read in
        // place) or once to a row: SwiftUI keeps no position of its own here, which it would put
        // back over those as the conversation changes.
        ScrollViewReader { proxy in
            scrollView(proxy)
        }
    }

    private func scrollView(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: spacing) {
                rows
            }
            .environment(\.scrollAnchor, anchor)
            .padding(.horizontal, Metrics.gutter)
            // Room under the card's header, which the conversation scrolls beneath.
            .padding(.top, 16)
            // Room under the last message, so it doesn't sit on the composer.
            .padding(.bottom, 32)
            .readableColumn()
            .coordinateSpace(.named(ScrollAnchor.space))
            .background { ScrollViewFinder { anchor.scrollView = $0 } }
            .animation(animation, value: change)
        }
        .modifier(SelectionMenu(addToChat: quote))
        // Only where it starts. An anchor for size changes fought the rubber band: the lazy
        // stack re-measures rows during a bounce, so the end kept moving and the bounce
        // crawled, then snapped back. Following the end is done below, only while idle.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollPhaseChange { _, phase in
            scrolling.isOn = phase != .idle
            #if DEBUG
            ScrollFrameMonitor.shared.scrolling(phase != .idle)
            #endif
        }
        // One watcher for both, as SwiftUI passes on only one change a frame from each.
        .onScrollGeometryChange(for: EndGeometry.self) { geometry in
            let end = max(-geometry.contentInsets.top, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
            return EndGeometry(atEnd: geometry.visibleRect.maxY >= geometry.contentSize.height - 40, height: geometry.contentSize.height,
                               fits: geometry.contentSize.height <= geometry.containerSize.height + 1,
                               visible: geometry.containerSize.height, isPastEnd: geometry.contentOffset.y > end + 1)
        } action: { old, new in
            scroller.fits = new.fits
            // Thinking that was under way is done: for a moment, the conversation getting much
            // shorter is it folding. (Seen here, as the layout that makes it shorter.)
            if fold.thinking != thinking {
                if let done = fold.thinking { fold.folded = (done.row, .now + .seconds(1)) }
                fold.thinking = thinking
            }
            if endFollower.isSettling { return }
            // A row that got much shorter (long thinking folding into its summary), seen from the
            // end. The lazy stack re-measures only the rows it lays out in view: it goes on keeping
            // the row's old room, and following "the bottom" lands below the rows, looking at
            // nothing, each time a little less. So first to the row's top, which is where it's
            // laid out, so the rows from there are measured, then to the end.
            if let folded = fold.folded, folded.until > .now, !scrolling.isOn,
               new.isPastEnd || (scroller.followsEnd && old.height - new.height > new.visible) {
                fold.folded = nil
                endFollower.settle {
                    proxy.scrollTo(folded.row, anchor: .top)
                } then: {
                    anchor.scroll(to: nil)
                }
                return
            }
            // Your scrolling decides; growth below the fold doesn't. Set only when it changes: each
            // setting draws the conversation again, and this runs on every frame of a scroll.
            if scrolling.isOn { scroller.follow(new.atEnd) }
            // Shrinking too: the lazy stack's first guess at the height can be too big, and a
            // conversation would then open part of the way up.
            guard scroller.followsEnd, !scrolling.isOn, new.height != old.height else { return }
            endFollower.follow {
                // Later, you may have started scrolling meanwhile.
                guard scroller.followsEnd, !scrolling.isOn else { return }
                anchor.scroll(to: nil)
            }
        }
        // Where it's scrolled to, for going to a place (a plain value, read only then).
        .onScrollGeometryChange(for: ScrollSpot.Geometry.self) { ScrollSpot.Geometry(offset: $0.contentOffset.y, height: $0.containerSize.height) } action: { _, new in
            spot.geometry = new
            anchor.isFollowingEnd = scroller.followsEnd
            anchor.viewMoved(offset: new.offset, height: new.height)
            if let nearTop, !scroller.followsEnd, new.offset < new.height * 2 { nearTop() }
        }
        // Messages scroll on under the card's header and the composer, blurring away there
        // instead of being cut at an edge.
        .scrollEdgeEffectStyle(Self.edgeStyle, for: .all)
        .overlay(alignment: .bottom) {
            // Scrolled up: a way back to the newest, which also follows it again.
            if !scroller.followsEnd {
                Button {
                    scroller.toEnd(animated: true)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Scroll to the End")
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.ui, value: scroller.followsEnd)
        .onChange(of: scroller.requests) {
            switch scroller.request {
            case .end(let animated):
                anchor.scroll(to: nil, animated: animated)
            case .row(let id):
                withAnimation(.ui) { proxy.scrollTo(id, anchor: .center) }
            case .place(let id, let fraction):
                // Lined up so the place is as far down the view as it is down its row (in view,
                // however tall the row), then moved to the middle.
                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: fraction))
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard scroller.request == .place(id, fraction) else { return }
                    anchor.scroll(to: max(0, spot.geometry.offset + (fraction - 0.5) * spot.geometry.height))
                }
            case .offset(let y):
                anchor.scroll(to: y)
            case nil:
                break
            }
        }
    }
}

/// Where the conversation is scrolled to, read only when going to a place.
final class ScrollSpot {
    struct Geometry: Equatable {
        var offset: CGFloat = 0
        var height: CGFloat = 0
    }

    var geometry = Geometry()
}

/// Thinking under way: its row, and which of the row's steps it is.
struct Thinking: Equatable {
    var row: String
    var step: Int
}

/// The thinking under way as last seen, and the row of thinking that just folded.
final class FoldWatch {
    var thinking: Thinking?
    var folded: (row: String, until: ContinuousClock.Instant)?
}

/// Set while you scroll, read by the handlers only.
final class ScrollingFlag {
    var isOn = false
}

/// Whether the end is in view, and how tall the conversation is.
struct EndGeometry: Equatable {
    var atEnd: Bool
    var height: CGFloat
    var fits = false
    /// How tall the view of it is, and whether it's scrolled past its end.
    var visible: CGFloat = 0
    var isPastEnd = false
}

/// Keeps the end in view as the conversation grows. Scrolling makes the lazy stack make the rows
/// it comes to, which measure taller or shorter than it guessed, so the height changes again in
/// the same frame, and SwiftUI drops scroll geometry updates that come more than once a frame. A
/// height that shrank and was dropped left it scrolled past the end: a blank conversation until
/// something laid it out again (showing the panel). So each change scrolls at once (a
/// conversation opens at its end), again on the next turn of the run loop for the changes after
/// it, and once more when they've settled, for any that weren't passed on.
final class EndFollower {
    private var isBusy = false
    private var settle: Task<Void, Never>?
    private(set) var isSettling = false

    /// `first`, then, once the conversation has been laid out there, `then`; following the end
    /// waits meanwhile, as it would undo `first`.
    func settle(first: @escaping () -> Void, then: @escaping () -> Void) {
        isSettling = true
        settle?.cancel()
        first()
        settle = Task {
            try? await Task.sleep(for: .milliseconds(150))
            isSettling = false
            then()
        }
    }

    func follow(_ scroll: @escaping () -> Void) {
        if !isBusy {
            isBusy = true
            scroll()
            DispatchQueue.main.async { [self] in
                isBusy = false
                scroll()
            }
        }
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            scroll()
        }
    }
}

/// Keeps what you're reading where it is while rows above it change height: rows made as they
/// come into view (scrolling up, they're above it) measure taller or shorter than the lazy stack
/// guessed, and earlier messages come in above, which moved everything after them. The row at the
/// top of the view is noted, and when it moves in the conversation, the view moves with it, at
/// once, before it's drawn. It also moves the view to the end or to a place: through AppKit's
/// scroll view, as SwiftUI would put a position of its own back over what this did.
final class ScrollAnchor {
    static let space = "conversation"
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.environment["KUVO_PERF_NO_ANCHOR"] == nil
    #else
    static let isOn = true
    #endif

    weak var scrollView: NSScrollView? {
        didSet {
            #if DEBUG
            if scrollView !== oldValue, scrollView != nil { Self.latest = self }
            #endif
        }
    }
    var isFollowingEnd = true
    /// The rows laid out, where they are in the conversation, and those shown now. A row that
    /// goes and comes back where it was (the whole conversation hidden a moment) isn't told its
    /// place again, so where it was is kept.
    private var frames: [String: CGRect] = [:]
    private var shown: Set<String> = []
    /// The row kept in place, and where it was.
    private var anchor: (id: String, minY: CGFloat)?

    #if DEBUG
    /// What it did lately, the one in use, and where its rows are, for the scrolling test.
    static var notes: [String] = []
    static weak var latest: ScrollAnchor?
    var conversationFrames: [String: CGRect] { frames }
    private static func note(_ text: String) {
        notes.append(text)
        if notes.count > 40 { notes.removeFirst() }
    }
    #endif

    func rowMoved(_ id: String, to frame: CGRect) {
        frames[id] = frame
        shown.insert(id)
        guard Self.isOn, let anchor, anchor.id == id else { return }
        let shift = frame.minY - anchor.minY
        self.anchor?.minY = frame.minY
        guard abs(shift) > 0.5, !isFollowingEnd, let scrollView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        // Not while it bounces at an edge.
        guard origin.y >= 0, origin.y <= (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height else { return }
        origin.y += shift
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        #if DEBUG
        Self.note("\(id) moved \(Int(shift))")
        #endif
    }

    /// To `y` in the conversation (nil: its end).
    func scroll(to y: CGFloat?, animated: Bool = false) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y = y ?? (scrollView.documentView?.frame.height ?? 0) + 10_000
        let target = clip.constrainBoundsRect(bounds).origin
        guard abs(target.y - clip.bounds.origin.y) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(target)
            } completionHandler: { [weak scrollView] in
                scrollView?.reflectScrolledClipView(clip)
            }
        } else {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func rowCame(_ id: String) {
        if frames[id] != nil { shown.insert(id) }
    }

    func rowGone(_ id: String) {
        shown.remove(id)
        if anchor?.id == id { anchor = nil }
    }

    /// The view scrolled: the first row that starts in it is the one to keep in place (or, with
    /// none, the one across it).
    func viewMoved(offset: CGFloat, height: CGFloat) {
        if let anchor, let frame = frames[anchor.id], frame.minY >= offset, frame.minY < offset + height { return }
        let rows = frames.filter { shown.contains($0.key) }
        let first = rows.filter { $0.value.minY >= offset && $0.value.minY < offset + height }.min { $0.value.minY < $1.value.minY }
            ?? rows.filter { $0.value.maxY > offset && $0.value.minY < offset + height }.min { $0.value.minY < $1.value.minY }
        #if DEBUG
        if first?.key != anchor?.id { Self.note("anchor \(first?.key ?? "none of \(rows.count)") at \(Int(offset))") }
        #endif
        anchor = first.map { ($0.key, $0.value.minY) }
    }
}

extension EnvironmentValues {
    @Entry var scrollAnchor: ScrollAnchor?
}

extension View {
    /// A row of a conversation, kept in place as rows above it change (see `ScrollAnchor`).
    func conversationRow(_ id: String) -> some View {
        modifier(ConversationRow(id: id))
    }
}

private struct ConversationRow: ViewModifier {
    let id: String
    @Environment(\.scrollAnchor) private var anchor

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ScrollAnchor.space)) } action: { anchor?.rowMoved(id, to: $0) }
            .onAppear { anchor?.rowCame(id) }
            .onDisappear { anchor?.rowGone(id) }
    }
}

/// The scroll view its background is in, once it's there.
private struct ScrollViewFinder: NSViewRepresentable {
    let found: (NSScrollView) -> Void

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: FinderView, context: Context) {
        view.found = found
    }

    final class FinderView: NSView {
        var found: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            found?(scrollView)
        }
    }
}
