import AppKit
import SwiftUI

/// The ten file categories of §3.2. The single source for the map colors, the legend, the 類型
/// menus and the inspector. Imports AppKit/SwiftUI only, so the contrast table can be checked by a
/// standalone script without the scanner.
enum FileCategory: Int, CaseIterable, Identifiable, Hashable {
    case video, image, audio, document, code, archive, app, model, design, other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .video: return String(localized: "影片")
        case .image: return String(localized: "圖片")
        case .audio: return String(localized: "音訊")
        case .document: return String(localized: "文件")
        case .code: return String(localized: "程式碼與開發")
        case .archive: return String(localized: "封存與磁碟映像")
        case .app: return String(localized: "App 與函式庫")
        case .model: return String(localized: "模型與資料")
        case .design: return String(localized: "設計與 3D")
        case .other: return String(localized: "其他")
        }
    }

    /// Shown in tiles when "Differentiate without color" is on (§3.2 rule 7).
    var symbol: String {
        switch self {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archive: return "archivebox"
        case .app: return "app"
        case .model: return "cylinder"
        case .design: return "cube"
        case .other: return "questionmark.square"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .video: return .systemPurple
        case .image: return .systemCyan
        case .audio: return .systemPink
        case .document: return .systemBlue
        case .code: return .systemGreen
        case .archive: return .systemOrange
        case .app: return .systemIndigo
        case .model: return .systemYellow
        case .design: return .systemBrown
        case .other: return .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    static let extensions: [FileCategory: [String]] = [
        .video: ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mts", "m2ts", "3gp", "braw", "r3d"],
        .image: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "raw", "dng", "cr2", "cr3",
                 "nef", "arw", "svg", "ico", "icns", "exr", "hdr"],
        .audio: ["mp3", "wav", "m4a", "aac", "aiff", "aif", "flac", "ogg", "opus", "caf", "mid", "midi"],
        .document: ["pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "epub"],
        .code: ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "h", "cpp", "m", "java", "kt", "rb", "php", "html",
                "css", "json", "yaml", "yml", "toml", "xml", "sh", "o", "a", "pyc", "class", "jar", "map", "lock", "wasm"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "dmg", "iso", "img"],
        .app: ["pkg", "ipa", "dylib", "so", "dll", "exe", "kext"],
        .model: ["safetensors", "gguf", "ggml", "pt", "pth", "ckpt", "onnx", "mlmodel", "npy", "npz", "h5", "hdf5",
                 "parquet", "arrow", "csv", "tsv", "jsonl", "db", "sqlite", "sqlite3", "realm"],
        .design: ["psd", "ai", "sketch", "fig", "blend", "fbx", "obj", "glb", "gltf", "usdz", "usd", "vrm", "c4d", "ma",
                  "mb", "aep", "prproj", "afphoto", "afdesign", "procreate"],
    ]

    private static let lookup: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        for (category, list) in extensions {
            for ext in list {
                precondition(map[ext] == nil, "extension .\(ext) is in two categories")
                map[ext] = category
            }
        }
        return map
    }()

    /// `ext` is lowercased without the dot, "" when the file has none.
    static func of(extension ext: String) -> FileCategory { lookup[ext] ?? .other }

    // MARK: Fill and label colors (§3.2 rules 1–4: this is the tested contract)

    struct Look: Hashable { var dark: Bool; var highContrast: Bool }

    static let looks: [Look] = [Look(dark: false, highContrast: false), Look(dark: true, highContrast: false),
                                Look(dark: false, highContrast: true), Look(dark: true, highContrast: true)]

    struct RGB: Equatable { var r, g, b: Double }

    private static func appearance(_ look: Look) -> NSAppearance? {
        switch (look.dark, look.highContrast) {
        case (false, false): return NSAppearance(named: .aqua)
        case (true, false): return NSAppearance(named: .darkAqua)
        case (false, true): return NSAppearance(named: .accessibilityHighContrastAqua)
        case (true, true): return NSAppearance(named: .accessibilityHighContrastDarkAqua)
        }
    }

    static func resolve(_ color: NSColor, _ look: Look) -> RGB {
        var out = RGB(r: 0.5, g: 0.5, b: 0.5)
        let resolveNow = {
            if let c = color.usingColorSpace(.sRGB) {
                out = RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
            }
        }
        if let appearance = appearance(look) { appearance.performAsCurrentDrawingAppearance(resolveNow) } else { resolveNow() }
        return out
    }

    /// Opaque tile fill: the category color at 55% (75% with Increase Contrast) over the window background.
    func fill(_ look: Look) -> RGB { Self.cache(self, look, folder: false).fill }

    /// True when black text reads better than white on this category's fill.
    func labelIsBlack(_ look: Look) -> Bool { Self.cache(self, look, folder: false).black }

    /// Opaque fill of a folder tile whose dominant category is this one: 35% (55% with Increase
    /// Contrast), so a file still reads stronger than a folder.
    func folderFill(_ look: Look) -> RGB { Self.cache(self, look, folder: true).fill }

    func folderLabelIsBlack(_ look: Look) -> Bool { Self.cache(self, look, folder: true).black }

    private static var table: [Int: (fill: RGB, black: Bool)] = [:]

    private static func cache(_ category: FileCategory, _ look: Look, folder: Bool) -> (fill: RGB, black: Bool) {
        let key = category.rawValue * 8 + (look.dark ? 1 : 0) + (look.highContrast ? 2 : 0) + (folder ? 4 : 0)
        if let hit = table[key] { return hit }
        let base = resolve(category.nsColor, look)
        let back = resolve(.windowBackgroundColor, look)
        let alpha = folder ? (look.highContrast ? 0.55 : 0.35) : (look.highContrast ? 0.75 : 0.55)
        let fill = RGB(r: base.r * alpha + back.r * (1 - alpha), g: base.g * alpha + back.g * (1 - alpha),
                       b: base.b * alpha + back.b * (1 - alpha))
        let black = contrast(fill, RGB(r: 0, g: 0, b: 0)) >= contrast(fill, RGB(r: 1, g: 1, b: 1))
        table[key] = (fill, black)
        return (fill, black)
    }

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG 2 contrast ratio.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Label contrast for every category × appearance × file/folder fill (§3.2 rule 3). Each must be ≥ 4.5.
    static func contrastTable() -> [(category: FileCategory, look: Look, folder: Bool, ratio: Double)] {
        var rows: [(FileCategory, Look, Bool, Double)] = []
        for category in allCases {
            for look in looks {
                for folder in [false, true] {
                    let entry = cache(category, look, folder: folder)
                    let text = entry.black ? RGB(r: 0, g: 0, b: 0) : RGB(r: 1, g: 1, b: 1)
                    rows.append((category, look, folder, contrast(entry.fill, text)))
                }
            }
        }
        return rows
    }
}

extension FileCategory.RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}
