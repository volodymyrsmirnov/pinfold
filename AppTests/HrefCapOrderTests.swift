@testable import Pinfold
import Testing

/// D8: the 500-href cap keeps icons first, then photo links, then description images.
struct HrefCapOrderTests {
    @Test func iconsAndPhotosSurviveAFloodOfDescriptionImages() {
        let images = Set((0 ..< 700).map { "https://a.example/img\($0).png" })
        let capped = ImportService.cappedHrefs(
            icons: ["https://z.example/icon.png"], photos: ["https://y.example/photo.jpg"], images: images
        )
        #expect(capped.count == 500)
        #expect(capped[0] == "https://z.example/icon.png")
        #expect(capped[1] == "https://y.example/photo.jpg")
    }

    @Test func orderIsDeterministicAndDeduplicated() {
        let shared = "https://x.example/shared.png"
        let capped = ImportService.cappedHrefs(icons: [shared], photos: [shared, "https://b/p.png"], images: [shared])
        #expect(capped == [shared, "https://b/p.png"])
    }
}
