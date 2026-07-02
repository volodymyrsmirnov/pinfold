import CoreGraphics
@testable import Pinfold
import Testing

/// Tests for `RowFrameBox.anchorRowID()` — pure geometry: pick the realized row whose top
/// is nearest the list's content top (offset by the calibrated restore landing position),
/// skipping rows scrolled fully above it.
struct RowFrameBoxTests {
    private func makeBox(listTop: CGFloat = 100) -> RowFrameBox {
        let box = RowFrameBox()
        box.listFrame = CGRect(x: 0, y: listTop, width: 400, height: 600)
        return box
    }

    @Test func noListFrame_returnsNil() {
        let box = RowFrameBox()
        box.frames["p0"] = CGRect(x: 0, y: 0, width: 400, height: 50)
        #expect(box.anchorRowID() == nil)
    }

    @Test func noRows_returnsNil() {
        #expect(makeBox().anchorRowID() == nil)
    }

    @Test func picksRowNearestListTop() {
        let box = makeBox(listTop: 100)
        box.frames["above"] = CGRect(x: 0, y: 0, width: 400, height: 50) // fully scrolled off
        box.frames["top"] = CGRect(x: 0, y: 95, width: 400, height: 50) // straddles the top
        box.frames["below"] = CGRect(x: 0, y: 145, width: 400, height: 50)
        #expect(box.anchorRowID() == "top")
    }

    @Test func fullyScrolledOffRows_areIgnored() {
        let box = makeBox(listTop: 100)
        box.frames["gone"] = CGRect(x: 0, y: 20, width: 400, height: 50) // maxY 70 < top
        box.frames["visible"] = CGRect(x: 0, y: 200, width: 400, height: 50)
        #expect(box.anchorRowID() == "visible")
    }

    @Test func calibrationOffset_shiftsReference() {
        let box = makeBox(listTop: 100)
        box.restoredTopOffset = 40 // restore landed rows at listTop + 40
        box.frames["a"] = CGRect(x: 0, y: 105, width: 400, height: 50)
        box.frames["b"] = CGRect(x: 0, y: 141, width: 400, height: 50) // nearest to 140
        #expect(box.anchorRowID() == "b")
    }

    @Test func reset_clearsFramesAndCalibration() {
        let box = makeBox()
        box.frames["a"] = .zero
        box.restoredTopOffset = 12
        box.reset()
        #expect(box.frames.isEmpty)
        #expect(box.restoredTopOffset == nil)
        #expect(box.anchorRowID() == nil)
    }
}
