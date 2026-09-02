import AppKit
import Foundation

/// Acts on web content by running JavaScript in the frontmost browser tab via AppleScript.
/// Targets real DOM elements, so it beats pixel-clicking on any page. The user must enable
/// "Allow JavaScript from Apple Events" once (Safari: Develop menu; Chrome: View → Developer).
/// Ported from cursor-voice (MIT) BrowserBridge.
enum AgentBrowser {

    enum Browser: String, CaseIterable {
        case safari = "Safari"
        case chrome = "Google Chrome"
        case brave = "Brave Browser"
        case edge = "Microsoft Edge"
        case arc = "Arc"

        func script(forJS js: String) -> String {
            let escaped = js
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            switch self {
            case .safari:
                return """
                    tell application "Safari"
                        set theResult to (do JavaScript "\(escaped)" in current tab of front window)
                        return theResult as text
                    end tell
                    """
            case .chrome, .brave, .edge, .arc:
                return """
                    tell application "\(rawValue)"
                        set theResult to (execute active tab of front window javascript "\(escaped)")
                        return theResult as text
                    end tell
                    """
            }
        }
    }

    @MainActor
    static func frontmostBrowser() -> Browser? {
        Browser(rawValue: NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
    }

    @MainActor
    static func runJS(_ js: String) -> [String: Any] {
        guard !js.isEmpty else { return ["error": "js is required"] }
        guard let browser = frontmostBrowser() else {
            return ["error": "frontmost app is not a supported browser (Safari, Chrome, Brave, Edge, Arc) — activate one first"]
        }
        let out = AgentAppleScript.run(browser.script(forJS: js))
        if let error = out["error"] as? String, !error.isEmpty {
            return ["error": error, "hint": "Enable “Allow JavaScript from Apple Events” in \(browser.rawValue)'s Develop/Developer menu."]
        }
        return ["browser": browser.rawValue, "result": out["result"] ?? ""]
    }

    @MainActor
    static func clickText(_ query: String) -> [String: Any] {
        guard !query.isEmpty else { return ["error": "text is required"] }
        let q = query.replacingOccurrences(of: "'", with: "\\'")
        let js = """
            (function(){
              var q='\(q)'.toLowerCase();
              var els=[].slice.call(document.querySelectorAll('a,button,[role=button],input[type=submit],input[type=button],[onclick],summary,[tabindex]'));
              function txt(e){return ((e.innerText||e.value||e.getAttribute('aria-label')||e.title||'')+'').trim().toLowerCase();}
              var hit=els.find(function(e){var t=txt(e);return t&&t.indexOf(q)>=0&&e.offsetParent!==null;});
              if(!hit){var all=[].slice.call(document.querySelectorAll('*'));hit=all.find(function(e){return txt(e)===q&&e.offsetParent!==null;});}
              if(!hit) return 'NOT_FOUND';
              hit.scrollIntoView({block:'center'}); hit.click();
              return 'CLICKED: '+txt(hit).slice(0,60);
            })();
            """
        let result = runJS(js)
        if let r = result["result"] as? String, r == "NOT_FOUND" {
            return ["error": "no clickable element matching \"\(query)\"", "hint": "call browser_snapshot to see what's on the page"]
        }
        return result
    }

    @MainActor
    static func snapshot() -> [String: Any] {
        let js = """
            (function(){
              var out=[];
              var els=[].slice.call(document.querySelectorAll('a,button,[role=button],input,textarea,select,summary'));
              for(var i=0;i<els.length && out.length<60;i++){
                var e=els[i]; if(e.offsetParent===null) continue;
                var t=((e.innerText||e.value||e.getAttribute('aria-label')||e.placeholder||e.title||'')+'').trim().replace(/\\s+/g,' ').slice(0,70);
                if(!t) continue; out.push(e.tagName.toLowerCase()+': '+t);
              }
              return JSON.stringify({url:location.href,title:document.title,elements:out});
            })();
            """
        let result = runJS(js)
        guard let raw = result["result"] as? String, let data = raw.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return result }
        var merged = parsed
        merged["browser"] = result["browser"]
        return merged
    }

    @MainActor
    static func listTabs() -> [String: Any] {
        guard let browser = frontmostBrowser() else { return ["error": "frontmost app is not a supported browser"] }
        let script: String
        switch browser {
        case .safari:
            script = """
                set out to ""
                tell application "Safari"
                  set i to 1
                  repeat with t in tabs of front window
                    set out to out & i & " | " & (name of t) & " | " & (URL of t) & linefeed
                    set i to i + 1
                  end repeat
                end tell
                return out
                """
        default:
            script = """
                set out to ""
                tell application "\(browser.rawValue)"
                  set i to 1
                  repeat with t in tabs of front window
                    set out to out & i & " | " & (title of t) & " | " & (URL of t) & linefeed
                    set i to i + 1
                  end repeat
                end tell
                return out
                """
        }
        let out = AgentAppleScript.run(script)
        guard let text = out["result"] as? String else { return out }
        let tabs = text.split(separator: "\n").map { line -> [String: Any] in
            let parts = line.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            return ["index": Int(parts.first ?? "") ?? 0, "title": parts.count > 1 ? parts[1] : "", "url": parts.count > 2 ? parts[2] : ""]
        }
        return ["browser": browser.rawValue, "tabs": tabs, "count": tabs.count]
    }

    @MainActor
    static func switchTab(index: Int) -> [String: Any] {
        guard let browser = frontmostBrowser() else { return ["error": "frontmost app is not a supported browser"] }
        guard index >= 1 else { return ["error": "index must be 1 or higher"] }
        let script: String
        switch browser {
        case .safari:
            script = "tell application \"Safari\" to set current tab of front window to tab \(index) of front window"
        default:
            script = "tell application \"\(browser.rawValue)\" to set active tab index of front window to \(index)"
        }
        let out = AgentAppleScript.run(script)
        return out["error"] != nil ? out : ["ok": true, "browser": browser.rawValue, "tab": index]
    }
}
