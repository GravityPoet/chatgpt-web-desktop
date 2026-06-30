import Foundation

public enum DownloadFilename {
    public static func uniqueDownloadURL(
        suggestedFilename: String,
        in directory: URL,
        fileExists: (String) -> Bool
    ) -> URL {
        let sanitized = sanitize(suggestedFilename)
        let ext = URL(fileURLWithPath: sanitized).pathExtension
        let stem = URL(fileURLWithPath: sanitized).deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(sanitized)
        var index = 1

        while fileExists(candidate.path) {
            let nextName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }

        return candidate
    }

    public static func sanitize(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet.controlCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "chatgpt-download" : cleaned
    }

    public static func remoteImageFilename(suggestedFilename: String?, sourceURL: URL, mimeType: String?) -> String {
        imageFilename(
            suggestedFilename: suggestedFilename,
            fallback: sourceURL.lastPathComponent.isEmpty ? "chatgpt-image" : sourceURL.lastPathComponent,
            mimeType: mimeType
        )
    }

    public static func imageFilename(suggestedFilename: String?, fallback: String, mimeType: String?) -> String {
        let rawName = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        var filename = rawName?.isEmpty == false ? rawName! : fallback
        if filename.isEmpty || filename == "/" {
            filename = "chatgpt-image"
        }

        if URL(fileURLWithPath: filename).pathExtension.isEmpty,
           let ext = fileExtension(forMIMEType: mimeType) {
            filename += ".\(ext)"
        }

        return filename
    }

    public static func fileExtension(forMIMEType mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        case "image/svg+xml":
            return "svg"
        case "image/avif":
            return "avif"
        case "image/heic":
            return "heic"
        default:
            return nil
        }
    }
}
