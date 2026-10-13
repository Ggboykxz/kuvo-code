import AppKit
import SwiftUI

/// A provider's mark, from the same logo set opencode's own apps use
/// (models.dev, by provider id). Monochrome, so it follows light and dark mode.
struct ProviderLogo: View {
    let id: String
    var size: CGFloat = 20

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(String(id.prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: id) { image = await LogoCache.shared.logo(for: id) }
    }
}

/// Logos are tiny and shared by every row, so fetch each once and keep it.
actor LogoCache {
    static let shared = LogoCache()

    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    func logo(for id: String) async -> NSImage? {
        if let image = images[id] { return image }
        if missing.contains(id) { return nil }
        if let task = inflight[id] { return await task.value }

        let task = Task<NSImage?, Never> {
            guard let url = URL(string: "https://models.opencode.ai/logos/\(id).svg"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            image.isTemplate = true
            return image
        }
        inflight[id] = task
        let image = await task.value
        inflight[id] = nil
        if let image { images[id] = image } else { missing.insert(id) }
        return image
    }
}
