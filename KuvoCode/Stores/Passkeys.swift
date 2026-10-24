import WebKit

/// Passkeys in the browsers agents use (the panel's here, and a machine's, which sends the same
/// script): not yet. A page that asks for one hears at once that there's none, rather than waiting
/// on a prompt that can't show (a machine's browser draws its passkey dialog where no one sees it,
/// and that dialog held the page still, so "Try another way" couldn't be clicked). Sites then
/// offer a password or their other ways, and say they can't use a passkey here. Replaced where
/// every way of asking reaches it, `CredentialsContainer.prototype.get.call(…)` too, which goes
/// round anything put on `navigator.credentials` itself.
nonisolated enum Passkeys {
    /// Run in the page's own world before anything else, in every frame.
    static let script = #"""
    (() => {
      try {
        const none = () => Promise.reject(new DOMException("Passkeys can't be used in this browser.", "NotAllowedError"));
        const Container = window.CredentialsContainer;
        if (Container && Container.prototype) {
          const prototype = Container.prototype, get = prototype.get, create = prototype.create;
          if (get) prototype.get = function (options) { return options && options.publicKey ? none() : get.call(this, options); };
          if (create) prototype.create = function (options) { return options && options.publicKey ? none() : create.call(this, options); };
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
