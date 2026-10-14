import Testing

@testable import VoxOS

/// type_text refuses only when the focus is clearly not a text field, so a model that typed
/// into a file picker is told so instead of reporting text that never landed.
@Suite
struct AgentTypingTargetTests {

    @Test func textFieldsAndUnknownViewsTakeTyping() {
        for role in ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea", "AXCustomEditor"] {
            #expect(AgentAXTree.acceptsTyping(role: role), "\(role) must still get the text")
        }
    }

    @Test func filePickersAndControlsDoNot() {
        for role in ["AXList", "AXOutline", "AXBrowser", "AXButton", "AXWindow", "AXSheet", "AXTable"] {
            #expect(!AgentAXTree.acceptsTyping(role: role), "\(role) never takes typed text")
        }
    }
}
