import Foundation

public enum ContentKind: String, CaseIterable, Codable, Sendable {
    case text, code, link, email, json, csv, markdown, richText, image, file

    public var label: String {
        switch self {
        case .text: return "Text"
        case .code: return "Code"
        case .link: return "Link"
        case .email: return "Email"
        case .json: return "JSON"
        case .csv: return "Table"
        case .markdown: return "Markdown"
        case .richText: return "Rich Text"
        case .image: return "Image"
        case .file: return "Files"
        }
    }

    public var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .email: return "envelope"
        case .json: return "curlybraces"
        case .csv: return "tablecells"
        case .markdown: return "number"
        case .richText: return "textformat"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

public enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, text, code, links, images, pinned, favorites, recent
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .code: return "Code"
        case .links: return "Links"
        case .images: return "Images"
        case .pinned: return "Pinned"
        case .favorites: return "Favourites"
        case .recent: return "Recent"
        }
    }

    var sql: String? {
        switch self {
        case .all: return nil
        case .text: return "kind IN ('text','csv','markdown','richText','file')"
        case .code: return "kind IN ('code','json')"
        case .links: return "kind IN ('link','email')"
        case .images: return "kind = 'image'"
        case .pinned: return "pinned = 1"
        case .favorites: return "favorite = 1"
        case .recent: return "last_copied_at > ?"
        }
    }
}

public struct ClipEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var kind: ContentKind
    /// A prefix of the content (see `HistoryStore.previewLimit`). Use `HistoryStore.payload` for the full text.
    public var text: String
    public var textLength: Int
    public var imageFile: String?
    public var imageWidth: Int
    public var imageHeight: Int
    public var byteSize: Int
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var copyCount: Int
    public var sourceApp: String?
    public var sourceBundleID: String?
    public var pinned: Bool
    public var favorite: Bool
    public var tags: [String]
    public var ocrText: String?
    public var hasRichText: Bool

    public var isTruncated: Bool { textLength > text.count }
}

/// What gets written back to the pasteboard.
public struct ClipPayload: Sendable {
    public var kind: ContentKind
    public var text: String?
    public var rtf: Data?
    public var html: Data?
    public var imageURL: URL?
    public var filePaths: [String]
}

/// A clip about to be stored.
public struct NewClip: Sendable {
    public var kind: ContentKind
    public var text: String?
    public var rtf: Data?
    public var html: Data?
    public var imagePNG: Data?
    public var imageWidth: Int = 0
    public var imageHeight: Int = 0
    public var sourceApp: String?
    public var sourceBundleID: String?

    public init(kind: ContentKind, text: String? = nil, rtf: Data? = nil, html: Data? = nil,
                imagePNG: Data? = nil, imageWidth: Int = 0, imageHeight: Int = 0,
                sourceApp: String? = nil, sourceBundleID: String? = nil) {
        self.kind = kind; self.text = text; self.rtf = rtf; self.html = html
        self.imagePNG = imagePNG; self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.sourceApp = sourceApp; self.sourceBundleID = sourceBundleID
    }
}
