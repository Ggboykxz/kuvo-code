import WebKit

/// Passkeys in the browsers agents use (the panel's here, and a machine's, which sends the same
/// script): not yet. A page that asks for one hears at once that there's none, rather than waiting
/// on a prompt that can't show (a machine's browser draws its passkey dialog where no one sees it,
/// and that dialog held the page still, so "Try another way" couldn't be clicked). Sites then
/// offer a password or their other ways, and say they can't use a passkey here.
nonisolated enum Passkeys {
    /// Run in the page's own world before anything else, in every frame.
    static let script = #"""
    (() => {
      try {
        const none = () => Promise.reject(new DOMException("Passkeys can't be used in this browser.", "NotAllowedError"));
        const credentials = navigator.credentials;
        if (credentials) {
          const get = credentials.get.bind(credentials), create = credentials.create.bind(credentials);
          credentials.get = (options) => (options && options.publicKey ? none() : get(options));
          credentials.create = (options) => (options && options.publicKey ? none() : create(options));
        }
        const Credential = window.PublicKeyCredential;
        if (Credential) {
          Credential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
          if (Credential.isConditionalMediationAvailable) Credential.isConditionalMediationAvailable = () => Promise.resolve(false);
        }
      } catch {}
    })();
    """#

    /// Adds the script to a configuration (once; windows a page opens share their opener's).
    @MainActor static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == script }) else { return }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }
}
