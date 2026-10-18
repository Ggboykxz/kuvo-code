import SwiftUI

extension StructuredText {
  /// The spacing a block's style sets, told up to the block stack: as a preference, which also
  /// gathers the spacing of blocks inside a list or quote for it, and as a layout value, which
  /// the stack reads in the same pass it lays the block out.
  struct BlockSpacingKey: PreferenceKey, LayoutValueKey {
    static let defaultValue = BlockSpacing()

    static func reduce(value: inout BlockSpacing, nextValue: () -> BlockSpacing) {
      value = value.union(nextValue())
    }
  }

  /// The spacing a block's style sets, read by the block stack from the block itself, so its
  /// first layout has it (the preference comes after that layout, and laid out again with it,
  /// the block moved under you).
  struct DeclaredBlockSpacingKey: LayoutValueKey {
    static let defaultValue: BlockSpacing? = nil
  }

  /// The spacing the block stack uses for a block once the preference has come (or a list
  /// item's, which is known at once); nil until then.
  struct ResolvedBlockSpacingKey: LayoutValueKey {
    static let defaultValue: BlockSpacing? = nil
  }
}
