import AppKit
import ApplicationServices

// focusnote <pid> <note title> <seconds>: opens the note from the sidebar of the app with that pid, puts the keyboard
// in its text, brings the app forward for that long, then gives the front back to the app that had it. Accessibility
// calls only, by pid: no keys are typed, so nothing can land in another app.
let arguments = CommandLine.arguments
guard arguments.count == 4, let pid = pid_t(arguments[1]), let seconds = Double(arguments[3]) else {
    print("usage: focusnote <pid> <note title> <seconds>"); exit(2)
}
let app = AXUIElementCreateApplication(pid)

func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var result: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

func find(_ element: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(element) { return element }
    guard depth < 30 else { return nil }
    for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if let found = find(child, depth: depth + 1, match) { return found }
    }
    return nil
}

func role(_ element: AXUIElement) -> String { value(element, kAXRoleAttribute) as? String ?? "" }

func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

guard let row = find(app, { element in
    role(element) == kAXRowRole && find(element, { (value($0, kAXTitleAttribute) as? String ?? value($0, kAXValueAttribute) as? String) == arguments[2] }) != nil
}) else { print("no sidebar row \(arguments[2])"); exit(1) }
AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
wait(1.5)
guard let text = find(app, { role($0) == kAXTextAreaRole && value($0, kAXDescriptionAttribute) as? String == "Note" }) else {
    print("no note text"); exit(1)
}
AXUIElementSetAttributeValue(text, kAXFocusedAttribute as CFString, kCFBooleanTrue)

let previous = NSWorkspace.shared.frontmostApplication
NSRunningApplication(processIdentifier: pid)?.activate()
wait(seconds)
let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
let focused = value(app, kAXFocusedUIElementAttribute).map { role($0 as! AXUIElement) } ?? "none"
let main = (value(app, kAXFocusedWindowAttribute) as! AXUIElement?).flatMap { value($0, kAXMainAttribute) as? Bool } ?? false
print("front \(front) key \(main) focused \(focused)")
FileHandle.standardOutput.synchronizeFile()
// The caller measures now; the front goes back after.
wait(8)
if previous?.processIdentifier != pid { previous?.activate() }
