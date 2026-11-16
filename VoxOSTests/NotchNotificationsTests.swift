import Foundation
import Testing

@testable import VoxOS

/// Notification Center's banners, read for the notch.
@Suite
@MainActor
struct NotchNotificationsTests {

    @Test func aBannersAppIsWhatItsDescriptionSaysBeforeTheTitle() {
        let banner = NotchNotifications.parse(
            id: "A", description: "Mail, Anna Berg, Lunch?, See you at one", title: "Anna Berg", subtitle: "Lunch?",
            body: "See you at one")
        #expect(banner?.app == "Mail")
        #expect(banner?.title == "Anna Berg")
        #expect(banner?.body == "Lunch? — See you at one")
        #expect(NotchNotifications.title(of: banner!) == "Mail · Anna Berg")
    }

    @Test func anAppNameWithACommaStaysWhole() {
        let banner = NotchNotifications.parse(
            id: "B", description: "Acme, Inc., Build done, All green", title: "Build done", subtitle: "",
            body: "All green")
        #expect(banner?.app == "Acme, Inc.")
    }

    @Test func aBannerWithoutATitleLeadsWithItsBody() {
        let banner = NotchNotifications.parse(
            id: "C", description: "Reminders, Water the plants", title: "", subtitle: "", body: "Water the plants")
        #expect(banner?.title == "Water the plants")
        #expect(banner?.app == "Reminders")
        #expect(NotchNotifications.parse(id: "D", description: "x", title: "", subtitle: "", body: "") == nil)
    }
}
