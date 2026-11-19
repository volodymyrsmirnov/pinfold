import Foundation

extension ResourceCache {
    // MARK: - Image sniffing

    /// Returns `true` if `data` begins with the magic bytes of an image format we render.
    ///
    /// Content-type response headers are unreliable (and absent for archive resources), and we
    /// hand these bytes straight to the image pipeline, so we sniff the actual bytes. Covers
    /// PNG, JPEG, GIF, WebP, BMP, TIFF, and the ISO-BMFF `ftyp` family (HEIC/HEIF/AVIF).
    static func looksLikeImage(_ data: Data) -> Bool {
        // Need at least the largest signature window we inspect (12 bytes for RIFF/WEBP & ftyp).
        guard data.count >= 12 else {
            // BMP ("BM") and the shortest TIFF/JPEG headers still fit in fewer bytes.
            return shortSignatureMatch(data)
        }
        let b = [UInt8](data.prefix(12))

        // PNG: 89 50 4E 47
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            return true
        }
        // JPEG: FF D8 FF
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return true
        }
        // GIF: 47 49 46 38 ("GIF8")
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 {
            return true
        }
        // BMP: 42 4D ("BM")
        if b[0] == 0x42, b[1] == 0x4D {
            return true
        }
        // TIFF little-endian "II*\0" / big-endian "MM\0*"
        if b[0] == 0x49, b[1] == 0x49, b[2] == 0x2A, b[3] == 0x00 {
            return true
        }
        if b[0] == 0x4D, b[1] == 0x4D, b[2] == 0x00, b[3] == 0x2A {
            return true
        }
        // WebP: "RIFF"...."WEBP"
        let isRIFF = b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
        if isRIFF, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            return true
        }
        // ISO-BMFF ftyp box (bytes 4-7 == "ftyp"), brand at bytes 8-11. Compare the brand as
        // raw ASCII bytes to avoid a Data→String conversion.
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = Array(b[8 ..< 12])
            let imageBrands: Set<[UInt8]> = [
                Array("heic".utf8), Array("heix".utf8), Array("hevc".utf8),
                Array("mif1".utf8), Array("msf1".utf8), Array("avif".utf8),
            ]
            if imageBrands.contains(brand) {
                return true
            }
        }
        return false
    }

    /// Signature check for payloads shorter than the 12-byte window (BMP, short TIFF/JPEG).
    fileprivate static func shortSignatureMatch(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(4))
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D {
            return true
        } // BMP
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return true
        } // JPEG
        if b.count >= 4 {
            if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
                return true
            } // PNG
            if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 {
                return true
            } // GIF
            if b[0] == 0x49, b[1] == 0x49, b[2] == 0x2A, b[3] == 0x00 {
                return true
            } // TIFF LE
            if b[0] == 0x4D, b[1] == 0x4D, b[2] == 0x00, b[3] == 0x2A {
                return true
            } // TIFF BE
        }
        return false
    }

    /// Returns `url` with its scheme upgraded from `http` to `https`; other URLs unchanged.
    static func httpsUpgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }
}
