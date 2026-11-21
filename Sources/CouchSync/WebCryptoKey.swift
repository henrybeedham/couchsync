import Foundation
import Security
import WebKit

/// When a page stores a WebCrypto key (Netflix does), WebKit encrypts it with
/// a master key that it otherwise keeps in the login keychain. Keychain access
/// is tied to the app's code signature, and CouchSync is signed ad hoc, so
/// every update looks like a different app and macOS would ask for the login
/// password. CouchSync hands WebKit its own master key instead, kept in
/// Application Support and readable only by this user.
enum WebCryptoKey {
    /// WebKit's master keys are 16 bytes.
    private static let size = 16

    static let data: Data = load()

    /// Installs the key on the web view's data store. The web view's
    /// navigation delegate answers WebKit's other way of asking (see below).
    static func install(on store: WKWebsiteDataStore) {
        let setter = NSSelectorFromString("set_delegate:")
        guard store.responds(to: setter) else { return }
        store.perform(setter, with: DataStoreDelegate.shared)
    }

    private static func load() -> Data {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CouchSync", isDirectory: true)
        let file = dir.appendingPathComponent("webcrypto-master.key")
        if let existing = try? Data(contentsOf: file), existing.count == size {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard SecRandomCopyBytes(kSecRandomDefault, size, &bytes) == errSecSuccess else {
            fatalError("No randomness for the WebCrypto key")
        }
        let key = Data(bytes)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: file.path, contents: key, attributes: [.posixPermissions: 0o600])
        return key
    }

    /// Answers WebKit's `_WKWebsiteDataStoreDelegate` request for the key.
    private final class DataStoreDelegate: NSObject {
        static let shared = DataStoreDelegate()

        @objc(webCryptoMasterKey:)
        func webCryptoMasterKey(_ completion: @escaping (Data?) -> Void) {
            log("webcrypto: key requested by data store")
            completion(WebCryptoKey.data)
        }
    }
}

extension WebController {
    /// WKNavigationDelegate's (private) way of asking for the key.
    @objc(_webCryptoMasterKeyForWebView:completionHandler:)
    func webCryptoMasterKey(for webView: WKWebView, completionHandler: @escaping (Data?) -> Void) {
        log("webcrypto: key requested by web view")
        completionHandler(WebCryptoKey.data)
    }

    @objc(_webCryptoMasterKeyForWebView:)
    func webCryptoMasterKey(for webView: WKWebView) -> Data? {
        log("webcrypto: key requested by web view (sync)")
        return WebCryptoKey.data
    }
}
