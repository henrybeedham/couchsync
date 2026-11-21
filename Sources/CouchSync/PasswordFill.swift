import AppKit
import SwiftUI
import WebKit

/// Fills a website's sign-in form from the Passwords app.
///
/// Passwords can't fill fields inside another app's web view, only native
/// ones. So CouchSync keeps two invisible native fields (username and
/// password) that can't be clicked or typed into. "Fill from Passwords"
/// focuses them and opens the system Passwords picker; as soon as the picker
/// fills them, the values go into the page's form and the fields are cleared.
/// The only window you see is Apple's own.
///
/// Sites that ask for the email first (Google, say) get the email; the
/// password is held for up to two minutes, for that same site only, until its
/// password box shows. On a page with only a password box, Passwords is asked
/// for the password.
final class SignInHelper {
    let userField = InertTextField()
    let passwordField = InertSecureTextField()

    private weak var web: WebController?
    private var poll: Timer?
    private var pending: (host: String, user: String, password: String, expires: Date)?

    init() {
        for field in [userField, passwordField] as [NSTextField] {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.alphaValue = 0.02
            field.font = .systemFont(ofSize: 1)
        }
        userField.contentType = .username
        passwordField.contentType = .password
    }

    func attach(_ web: WebController) { self.web = web }

    /// "Fill from Passwords".
    func begin() {
        guard let web else { return }
        let target = web.signInTarget
        guard target.secure else {
            web.notify("This page isn't secure (no https), so CouchSync won't fill it.")
            return
        }
        if let pending, pending.host == target.host, pending.expires > Date() {
            fill(user: pending.user, password: pending.password, host: target.host)
            return
        }
        pending = nil
        clearFields()
        Task { @MainActor in
            // Ask Passwords for whichever box the page is showing.
            let page = await web.fillSignIn(user: "", password: "")
            let field: NSTextField = page.pageHasPassword && !page.pageHasUser ? passwordField : userField
            guard let window = web.webView.window, window.makeFirstResponder(field) else { return }
            try? await Task.sleep(for: .milliseconds(100))
            if !PasswordsAutoFill.open() {
                finish()
                web.notify("Couldn't open Passwords. Try Edit → AutoFill → Passwords….")
                return
            }
            watch(host: target.host)
        }
    }

    /// Waits for the picker to fill the fields (or for you to give up on it).
    private func watch(host: String) {
        poll?.invalidate()
        let deadline = Date().addingTimeInterval(90)
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let user = self.userField.stringValue, password = self.passwordField.stringValue
            if !user.isEmpty || !password.isEmpty {
                timer.invalidate()
                // Give the picker a moment to fill the other one too.
                self.collect(host: host, until: Date().addingTimeInterval(1))
            } else if Date() > deadline {
                timer.invalidate()
                self.finish()
            }
        }
    }

    /// Waits until both fields are filled, or a second has passed.
    private func collect(host: String, until: Date) {
        let (u, p) = (userField.stringValue, passwordField.stringValue)
        if (!u.isEmpty && !p.isEmpty) || Date() > until {
            finish()
            fill(user: u, password: p, host: host)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.collect(host: host, until: until)
        }
    }

    private func fill(user: String, password: String, host: String) {
        guard let web else { return }
        Task { @MainActor in
            // The page may have moved on while the picker was open.
            guard web.signInTarget.host == host, web.signInTarget.secure else {
                self.pending = nil
                return
            }
            let result = await web.fillSignIn(user: user, password: password)
            log("fill: got user \(!user.isEmpty), password \(!password.isEmpty); page has user \(result.pageHasUser), password \(result.pageHasPassword); filled user \(result.filledUser), password \(result.filledPassword)")
            if result.filledPassword {
                self.pending = nil
            } else if !password.isEmpty && (result.filledUser || result.pageHasUser) {
                // A site that asks for the email first. Keep the password
                // for its next step.
                self.pending = (host, user, password, Date().addingTimeInterval(120))
                web.notify(result.filledUser
                    ? "Email filled. When the password box appears, choose Fill from Passwords again."
                    : "Passwords gave CouchSync your password but not your email. Type your email and continue, then choose Fill from Passwords again.")
            } else if result.filledUser {
                self.pending = nil
            } else if !result.pageHasUser && !result.pageHasPassword {
                self.pending = nil
                web.notify("There's no sign-in box on this page.")
            } else {
                self.pending = nil
                web.notify("Passwords didn't give CouchSync a login. Try again.")
            }
        }
    }

    /// Clears the invisible fields and hands the keyboard back to the page.
    private func finish() {
        poll?.invalidate()
        clearFields()
        if let web, let window = web.webView.window,
           window.firstResponder === userField.currentEditor() || window.firstResponder === passwordField.currentEditor()
            || window.firstResponder === userField || window.firstResponder === passwordField {
            window.makeFirstResponder(web.webView)
        }
    }

    private func clearFields() {
        userField.stringValue = ""
        passwordField.stringValue = ""
    }
}

/// Fields that only Passwords fills: they ignore the mouse.
final class InertTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class InertSecureTextField: NSSecureTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Puts the invisible fields in the window, where the picker anchors to them.
struct SignInFields: NSViewRepresentable {
    let helper: SignInHelper

    func makeNSView(context: Context) -> NSView {
        let container = PassthroughView()
        let stack = NSStackView(views: [helper.userField, helper.passwordField])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            helper.userField.widthAnchor.constraint(equalToConstant: 160),
            helper.passwordField.widthAnchor.constraint(equalToConstant: 160),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// What a fill did, and what sign-in boxes the page has.
struct FillResult {
    var filledUser = false
    var filledPassword = false
    var pageHasUser = false
    var pageHasPassword = false
}

/// Finds and runs the Edit → AutoFill → Passwords… menu command.
enum PasswordsAutoFill {
    @discardableResult
    static func open() -> Bool {
        guard let item = find(in: NSApp.mainMenu), let action = item.action else {
            log("autofill: no Passwords menu item")
            return false
        }
        log("autofill: \(NSStringFromSelector(action))")
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func find(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        menu.update()
        for item in menu.items {
            if let action = item.action,
               NSStringFromSelector(action).localizedCaseInsensitiveContains("password") {
                return item
            }
            if let found = find(in: item.submenu) { return found }
        }
        return nil
    }
}

/// Fills the page's sign-in form. It runs in CouchSync's own script world,
/// so the page can't see or tamper with it, and the values are passed as
/// arguments rather than written into the script.
enum SignInScript {
    static let source = #"""
    const visible = (el) => {
      const r = el.getBoundingClientRect();
      const s = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' &&
        !el.disabled && !el.readOnly;
    };
    const inputs = [...document.querySelectorAll('input')].filter(visible);
    const pass = inputs.find((i) => i.type === 'password');
    const describe = (i) => [i.autocomplete, i.name, i.id, i.placeholder, i.getAttribute('aria-label')].join(' ');
    const userish = (i) => ['email', 'text', 'tel'].includes(i.type) &&
      (i.type === 'email' || /user|email|login|account|identifier|phone/i.test(describe(i)));
    let field = null;
    if (pass) {
      // The username field is the last suitable one before the password.
      const before = inputs.filter((i) => i !== pass && (pass.compareDocumentPosition(i) & Node.DOCUMENT_POSITION_PRECEDING));
      field = before.reverse().find(userish) || before.find((i) => i.type === 'text' || i.type === 'email') || null;
    } else {
      field = inputs.find(userish) || null;
    }
    const set = (el, value) => {
      el.focus();
      el.value = value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const result = { hasUser: !!field, hasPassword: !!pass, user: false, password: false };
    if (field && user) { set(field, user); result.user = true; }
    if (pass && password) { set(pass, password); result.password = true; }
    return result;
    """#
}
