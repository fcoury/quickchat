import SwiftUI

/// A Markdown image belongs to the reply at its source position. Keep its description
/// readable when a remote image expires or the source cannot be displayed.
struct MarkdownImage: View {
    let url: URL
    let alt: String
    let link: URL?

    private var description: String {
        alt.isEmpty || alt == "\u{fffc}" ? "Image" : alt
    }

    var body: some View {
        if isDisplayable {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    if let link, ["https", "http"].contains(link.scheme?.lowercased()) {
                        Link(destination: link) { preview(image) }
                    } else {
                        preview(image)
                    }
                case .empty:
                    HStack { ProgressView().controlSize(.small); Text(description) }
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var isDisplayable: Bool {
        switch url.scheme?.lowercased() {
        case "https", "http":
            return url.host != nil && url.user == nil && url.password == nil
        case "data":
            return url.absoluteString.prefix(11).lowercased().hasPrefix("data:image/")
        default:
            return false
        }
    }

    private func preview(_ image: Image) -> some View {
        image.resizable().scaledToFit()
            .frame(maxWidth: 560, maxHeight: 340, alignment: .leading)
            .accessibilityLabel(description)
    }

    private var fallback: some View {
        Label(description, systemImage: "photo").foregroundStyle(.secondary)
            .help("Image unavailable")
    }
}
