import Foundation

/// Which copy of the app this process is. `make test` launches the app as a test host under
/// `com.achyuthkp.VoxOS.testhost`; to macOS that is a different app, so anything it does that
/// needs a permission (installing the keyboard tap) raises a fresh prompt on every test run and
/// leaves a second "VoxOS" row in Privacy settings. The test host hosts tests; it does not
/// need to listen to the keyboard.
enum ProcessIdentity {
    static let isTestHost = Bundle.main.bundleIdentifier?.hasSuffix(".testhost") == true
}
