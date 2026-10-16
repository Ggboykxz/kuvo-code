import SwiftUI

/// How a conversation scrolls, for the view showing it: whether it keeps to the end, and asking
/// it to go somewhere (back to the end, to a row Find found).
@Observable
final class ConversationScroller {
    enum Request: Equatable {
        case end(animated: Bool)
        case row(String)
        /// A row at the top, where it was, after rows came in above it.
        case top(String)
        /// A distance from the top, for the scrolling test.
        case offset(CGFloat)
    }

    /// Whether to keep the newest in view: true until you scroll up, true again once you scroll
    /// back to the end.
    var followsEnd = true
    /// All of it fits in view: nothing to scroll. (Not until it's known.)
    @ObservationIgnored fileprivate(set) var fits = false
    @ObservationIgnored fileprivate(set) var request: Request?
    /// Goes up with each request, for the scroll view to take it.
    fileprivate(set) var requests = 0

    /// To the end, following it again (you sent something).
    func toEnd(animated: Bool = false) {
        followsEnd = true
        ask(.end(animated: animated))
    }

    /// `id`'s row in the middle, and no following the end meanwhile.
    func reveal(_ id: String) {
        followsEnd = false
        ask(.row(id))
    }

    /// `id`'s row stays where it was at the top, as earlier rows come in above it.
    func keep(_ id: String) {
        ask(.top(id))
    }

    func scroll(to offset: CGFloat) {
        followsEnd = false
        ask(.offset(offset))
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
    /// Text you selected, to answer in the composer.
    let quote: (String) -> Void
    @ViewBuilder let rows: Rows

    @State private var position = ScrollPosition(edge: .bottom)
    /// Scrolling now: a plain flag, so starting and stopping don't redraw the conversation.
    @State private var scrolling = ScrollingFlag()
    @State private var endFollower = EndFollower()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: spacing) {
                rows
            }
            .padding(.horizontal, Metrics.gutter)
            // Room under the card's header, which the conversation scrolls beneath.
            .padding(.top, 16)
            // Room under the last message, so it doesn't sit on the composer.
            .padding(.bottom, 32)
            .readableColumn()
            .animation(animation, value: change)
        }
        .scrollPosition($position)
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
            EndGeometry(atEnd: geometry.visibleRect.maxY >= geometry.contentSize.height - 40, height: geometry.contentSize.height,
                        fits: geometry.contentSize.height <= geometry.containerSize.height + 1)
        } action: { old, new in
            scroller.fits = new.fits
            // Your scrolling decides; growth below the fold doesn't.
            if scrolling.isOn { scroller.followsEnd = new.atEnd }
            // Shrinking too: the lazy stack's first guess at the height can be too big, and a
            // conversation would then open part of the way up.
            guard scroller.followsEnd, !scrolling.isOn, new.height != old.height else { return }
            endFollower.follow {
                // Later, you may have started scrolling meanwhile.
                guard scroller.followsEnd, !scrolling.isOn else { return }
                position.scrollTo(edge: .bottom)
            }
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
                if animated {
                    withAnimation(.ui) { position.scrollTo(edge: .bottom) }
                } else {
                    position.scrollTo(edge: .bottom)
                }
            case .row(let id):
                withAnimation(.ui) { position.scrollTo(id: id, anchor: .center) }
            case .top(let id):
                position.scrollTo(id: id, anchor: .top)
            case .offset(let y):
                position.scrollTo(y: y)
            case nil:
                break
            }
        }
    }
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
