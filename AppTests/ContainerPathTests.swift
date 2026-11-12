@testable import Pinfold
import PinfoldCore
import Testing

/// `KMLContainer.container(atPath:)` resolves the outline's folder ids (paths of child indices).
struct ContainerPathTests {
    private func container(_ id: String, _ children: [KMLContainer] = []) -> KMLContainer {
        KMLContainer(id: id, name: id, children: children, placemarks: [], descriptionHTML: "<b>\(id)</b>")
    }

    private var tree: KMLContainer {
        container("root", [
            container("a", [container("a0"), container("a1", [container("a1x")])]),
            container("b"),
        ])
    }

    @Test func resolvesNestedPath() {
        #expect(tree.container(atPath: "")?.id == "root")
        #expect(tree.container(atPath: "0")?.id == "a")
        #expect(tree.container(atPath: "1")?.id == "b")
        #expect(tree.container(atPath: "0/1")?.id == "a1")
        #expect(tree.container(atPath: "0/1/0")?.id == "a1x")
    }

    @Test func invalidPathIsNil() {
        #expect(tree.container(atPath: "2") == nil)
        #expect(tree.container(atPath: "0/5") == nil)
        #expect(tree.container(atPath: "-1") == nil)
        #expect(tree.container(atPath: "x") == nil)
        #expect(tree.container(atPath: "0//1") == nil)
        #expect(tree.container(atPath: "1/0") == nil)
    }
}
