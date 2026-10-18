#if TEXTUAL_ENABLE_TEXT_SELECTION && canImport(AppKit) && !targetEnvironment(macCatalyst)
  import SwiftUI

  // MARK: - Overview
  //
  // `AppKitTextSelectionInteraction` presents the platform-specific text selection overlay for macOS.
  //
  // The modifier receives a `TextSelectionModel` and places it in the environment so selection highlights
  // and attachment dimming can access it. An overlay hosts `AppKitTextInteractionOverlay`, which wraps an
  // `NSView` that handles selection gestures and context menus. The modifier also manages cursor updates,
  // switching between I-beam and pointing hand based on hover position over text or links.

  typealias PlatformTextSelectionInteraction = AppKitTextSelectionInteraction

  /// When something last scrolled, to tell the pointer resting on text from text moving under
  /// it: scroll wheel events, and scroll views' live scrolling (a trackpad's, and its momentum).
  @MainActor enum ScrollWatch {
    private static var last: TimeInterval = 0
    private static var watchers: [Any] = []

    static var isIdle: Bool {
      if watchers.isEmpty {
        watchers.append(
          NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            last = ProcessInfo.processInfo.systemUptime
            return event
          } as Any)
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
          watchers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
              MainActor.assumeIsolated { last = ProcessInfo.processInfo.systemUptime }
            })
        }
      }
      return ProcessInfo.processInfo.systemUptime - last > 0.25
    }
  }

  struct AppKitTextSelectionInteraction: ViewModifier {
    @State private var cursorPushed = false

    private let model: TextSelectionModel

    init(model: TextSelectionModel) {
      self.model = model
    }

    func body(content: Content) -> some View {
      content
        // We need the selection model at text fragment level for the
        // text selection background and selected attachment dimming
        .environment(model)
        .overlayPreferenceValue(OverflowFrameKey.self) { frames in
          AppKitTextInteractionOverlay(model: model, overflowFrames: frames)
            .onContinuousHover { phase in
              updateCursor(for: phase, model: model)
            }
        }
    }

    private func updateCursor(for phase: HoverPhase, model: TextSelectionModel) {
      switch phase {
      case .active(let location):
        // The pointer rests on it, in the app you're using, not scrolling past: selecting may
        // come, so its text tells where it's laid out from now on.
        if !model.isActive, NSApp.isActive, ScrollWatch.isIdle {
          model.isActive = true
        }
        let cursor =
          model.url(for: location) != nil
          ? NSCursor.pointingHand
          : NSCursor.iBeam
        if !cursorPushed {
          cursor.push()
          cursorPushed = true
        } else {
          cursor.set()
        }
      case .ended:
        if cursorPushed {
          NSCursor.pop()
          cursorPushed = false
        }
      }
    }
  }
#endif
