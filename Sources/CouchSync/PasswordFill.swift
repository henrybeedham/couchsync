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
/// Sites that ask for the email first get the email; the password is held for
/// up to two minutes, for that same site only, until its password box shows.
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
        guard let window = web.webView.window, window.makeFirstResponder(userField) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if !PasswordsAutoFill.open() {
                self.finish()
                web.notify("Couldn't open Passwords. Try Edit → AutoFill → Passwords….")
                return
            }
            self.watch(host: target.host)
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
                // Let the picker finish filling the pair.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let (u, p) = (self.userField.stringValue, self.passwordField.stringValue)
                    self.finish()
                    self.fill(user: u, password: p, host: host)
                }
            } else if Date() > deadline {
                timer.invalidate()
                self.finish()
            }
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
            switch await web.fillSignIn(user: user, password: password) {
            case .both, .passwordOnly:
                self.pending = nil
            case .userOnly where !password.isEmpty:
                self.pending = (host, user, password, Date().addingTimeInterval(120))
                web.notify("Email filled. When the password box appears, choose Fill from Passwords again.")
            case .userOnly:
                self.pending = nil
            case .nothing:
                self.pending = nil
                web.notify("There's no sign-in box on this page.")
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

enum FillResult {
    case both, userOnly, passwordOnly, nothing
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
    const filled = [];
    if (field && user) { set(field, user); filled.push('user'); }
    if (pass && password) { set(pass, password); filled.push('password'); }
    return filled;
    """#
}
