import Foundation
@testable import Pinfold
import Testing

/// `SubscribePrompt`: the "Subscribe to URL" alert's state. What the person typed is never lost
/// to an error.
struct SubscribePromptTests {
    @Test func invalidAddress_showsTheErrorThenReopensWithTheTypedText() {
        var prompt = SubscribePrompt()
        prompt.begin()
        prompt.text = "example.com/map.kml"
        prompt.isPresented = false // tapping Subscribe closes the alert

        #expect(prompt.submit() == nil)
        #expect(prompt.error == String(localized: "Enter a web address that starts with https://"))

        prompt.dismissError()
        #expect(prompt.error == nil)
        #expect(prompt.isPresented)
        #expect(prompt.text == "example.com/map.kml")
    }

    @Test func validAddress_isNormalised_andTheTextIsKeptUntilItSucceeds() {
        var prompt = SubscribePrompt()
        prompt.begin()
        prompt.text = " http://example.com/map.kml "
        prompt.isPresented = false // tapping Subscribe closes the alert

        #expect(prompt.submit() == URL(string: "https://example.com/map.kml"))

        prompt.failed("The server returned an error (HTTP 404).")
        prompt.dismissError()
        #expect(!prompt.isPresented) // a fetch error doesn't reopen on its own...
        prompt.begin()
        #expect(prompt.text == " http://example.com/map.kml ") // ...but the next one starts with it

        prompt.succeeded()
        prompt.begin()
        #expect(prompt.text.isEmpty)
    }
}
