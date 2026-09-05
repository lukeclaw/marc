import AppKit
import Foundation
import MarcCore
import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case rendered
    case split
    case source

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .rendered: "doc.richtext"
        case .split: "rectangle.split.2x1"
        case .source: "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum SidebarPosition: String, CaseIterable, Identifiable, Codable {
    case left
    case right

    var id: String { rawValue }
}

enum TabSortOrder: String, CaseIterable, Identifiable, Codable {
    case opened
    case name
    case folder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .opened: "Open Order"
        case .name: "File Name"
        case .folder: "Folder"
        }
    }
}

struct DocumentGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var folderPath: String?
    var colorHex: String
    var isCollapsed: Bool

    var color: Color { Color(hex: colorHex) }
}

/// Where a change to a document's text came from.
enum ReadingUpdateOrigin {
    /// Typed in marc's own source editor.
    case localEdit
    /// Written by an agent, another editor, or a previous session.
    case external
}

enum BlockReadingStatus {
    case read
    case unread
    case changed
}

struct ReadingBlockRevision: Codable, Equatable {
    var id: String
    var signature: String
    /// Block kind and enclosing heading, absent in baselines written before
    /// revision matching existed. Treated as a wildcard when missing.
    var kind: String?
    var section: String?

    var identity: ReadingBlockIdentity {
        ReadingBlockIdentity(id: id, signature: signature, kind: kind, section: section)
    }
}

struct ReadingState: Codable, Equatable {
    var baseline: [ReadingBlockRevision]
    var readVersions: Set<String>
    var changedVersions: Set<String>
}

struct ThemeColor: Codable, Equatable {
    var hex: String

    var color: Color { Color(hex: hex) }
}

struct MarkdownTheme: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var fontFamily: String
    var bodySize: Double
    var pageWidth: Double
    var fullWidth: Bool? = nil
    var background: ThemeColor
    var text: ThemeColor
    var heading: ThemeColor
    var accent: ThemeColor
    var codeBackground: ThemeColor
    var quote: ThemeColor

    var usesFullWidth: Bool {
        get { fullWidth ?? false }
        set { fullWidth = newValue }
    }

    static let paper = MarkdownTheme(
        id: "paper",
        name: "Paper",
        fontFamily: "New York",
        bodySize: 16,
        pageWidth: 760,
        background: ThemeColor(hex: "#FBFAF7"),
        text: ThemeColor(hex: "#252422"),
        heading: ThemeColor(hex: "#4A5568"),
        accent: ThemeColor(hex: "#2B6CB0"),
        codeBackground: ThemeColor(hex: "#EEECE7"),
        quote: ThemeColor(hex: "#718096")
    )

    static let midnight = MarkdownTheme(
        id: "midnight",
        name: "Midnight",
        fontFamily: "Avenir Next",
        bodySize: 16,
        pageWidth: 780,
        background: ThemeColor(hex: "#111827"),
        text: ThemeColor(hex: "#E5E7EB"),
        heading: ThemeColor(hex: "#93C5FD"),
        accent: ThemeColor(hex: "#60A5FA"),
        codeBackground: ThemeColor(hex: "#1F2937"),
        quote: ThemeColor(hex: "#9CA3AF")
    )

    static let forest = MarkdownTheme(
        id: "forest",
        name: "Forest",
        fontFamily: "Charter",
        bodySize: 17,
        pageWidth: 740,
        background: ThemeColor(hex: "#F3F6F1"),
        text: ThemeColor(hex: "#243128"),
        heading: ThemeColor(hex: "#2F6B4F"),
        accent: ThemeColor(hex: "#3A7D5D"),
        codeBackground: ThemeColor(hex: "#E1E9DE"),
        quote: ThemeColor(hex: "#587064")
    )

    static let solar = MarkdownTheme(
        id: "solar",
        name: "Solar",
        fontFamily: "Georgia",
        bodySize: 17,
        pageWidth: 760,
        background: ThemeColor(hex: "#FFF8E7"),
        text: ThemeColor(hex: "#44392E"),
        heading: ThemeColor(hex: "#B45309"),
        accent: ThemeColor(hex: "#C2410C"),
        codeBackground: ThemeColor(hex: "#F5E9D0"),
        quote: ThemeColor(hex: "#8A6D4B")
    )

    static let presets = [paper, midnight, forest, solar]
}

struct FilePreferences: Codable, Equatable {
    var theme: MarkdownTheme = .paper
    var collapsedHeadingIDs: Set<String> = []
    var lastScrollHeadingID: String?
    var tableColumnWidths: [String: [Double]]?
    var tableWidthLayoutVersion: Int?
    var readingState: ReadingState?
}

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        var integer: UInt64 = 0
        Scanner(string: value).scanHexInt64(&integer)
        let red = Double((integer >> 16) & 0xFF) / 255
        let green = Double((integer >> 8) & 0xFF) / 255
        let blue = Double(integer & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02X%02X%02X",
            Int(nsColor.redComponent * 255),
            Int(nsColor.greenComponent * 255),
            Int(nsColor.blueComponent * 255)
        )
    }
}
