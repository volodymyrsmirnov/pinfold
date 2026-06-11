import Foundation

/// Sanitizes attacker-controlled filenames into a single safe path component.
///
/// Filenames arrive from untrusted sources (KML/KMZ metadata, share-extension URLs, the
/// "Open in Pinfold" association). A crafted name like `"images/evil.kml"` or `"../x.kml"`
/// would otherwise create nested paths under the per-entry folder and break the original-file
/// lookup (which only scans the folder's top level), or escape it entirely. This is the single
/// sanitizer applied at every import choke point.
///
/// Rules, in order:
/// 1. **Last path component only** — splits on both `/` and `\` and keeps the final segment,
///    so directory traversal (`../`, nested paths, Windows separators) is neutralized.
/// 2. **Strip control / separator chars** — NUL, newlines, tabs, and any other control
///    character or remaining separator becomes `-` (never silently dropped).
/// 3. **Strip leading dots** — no hidden files; `.hidden.kml` → `hidden.kml`.
/// 4. **Length cap (255 UTF-8 bytes)** — preserving the extension; the stem is truncated.
/// 5. **Fallback** — if nothing usable remains, returns the literal `"file"` (no extension is
///    assumed; callers append nothing).
///
/// Pure and deterministic; depends only on `String`/`Foundation` basics.
enum SafeFilename {
    /// The maximum filename length in UTF-8 bytes (the common filesystem limit).
    private static let maxBytes = 255

    /// Deterministic fallback when the input yields no usable name.
    private static let fallback = "file"

    static func sanitize(_ raw: String) -> String {
        // 1. Keep only the final path component. Split on both POSIX and Windows separators so
        //    "a/b/c", "a\b\c", and mixed forms all reduce to the last segment.
        //    Order is significant: the component split must precede control-character
        //    replacement (step 2) so a newline inside one segment can't merge content
        //    across a separator boundary ("a/b\nc.kml" → "b-c.kml", not "a-b-c.kml").
        let lastComponent = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""

        // 2. Replace control characters and any stray separators with "-".
        var cleaned = String(
            lastComponent.unicodeScalars.map { scalar -> Character in
                if scalar == "/" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) {
                    return "-"
                }
                return Character(scalar)
            }
        )

        // 3. Strip leading dots so the result is never a hidden file (and "..." can't survive).
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }

        // Trim surrounding whitespace that could make a name look empty / odd.
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        guard !cleaned.isEmpty else { return fallback }

        // 4. Cap to maxBytes UTF-8, preserving the extension.
        return capLength(cleaned)
    }

    /// Truncates `name` to `maxBytes` UTF-8 bytes, keeping its extension intact.
    private static func capLength(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }

        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension

        // Reserve room for "." + extension when there is one.
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let budget = maxBytes - suffix.utf8.count
        guard budget > 0 else {
            // Pathologically long extension: fall back to a hard byte-truncation of the whole name.
            return truncatedToBytes(name, budget: maxBytes)
        }
        let truncatedStem = truncatedToBytes(stem, budget: budget)
        let result = truncatedStem + suffix
        return result.isEmpty ? fallback : result
    }

    /// Returns the longest prefix of `string` whose UTF-8 encoding is at most `budget` bytes,
    /// never splitting a multi-byte scalar.
    private static func truncatedToBytes(_ string: String, budget: Int) -> String {
        guard string.utf8.count > budget else { return string }
        var result = ""
        var used = 0
        for character in string {
            let width = String(character).utf8.count
            if used + width > budget { break }
            result.append(character)
            used += width
        }
        return result
    }
}
