import AppKit
import AuthenticationServices
import BrokBotCore
import Foundation

/// Coordinates native macOS Google (`ASWebAuthenticationSession`) and Apple (`ASAuthorizationController`) sign-in flows.
@MainActor
final class MacAuthCoordinator: NSObject,
    ASWebAuthenticationPresentationContextProviding,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var webAuthSession: ASWebAuthenticationSession?
    private var appleContinuation: CheckedContinuation<(idToken: String, fullName: String?), Error>?

    func authorizeGoogle(
        config: FirebaseAppConfig,
        pkce: PKCEChallenge,
        authClient: FirebaseAuthClient
    ) async throws -> String {
        let authURL = try authClient.buildGoogleAuthorizationURL(config: config, pkce: pkce)
        let callbackScheme = config.reversedClientID

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.webAuthSession = nil
                }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: FirebaseAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                    continuation.resume(throwing: FirebaseAuthError.missingAuthorizationCode)
                    return
                }

                let queryMap = Dictionary(
                    (components.queryItems ?? []).compactMap { item -> (String, String)? in
                        guard let value = item.value else { return nil }
                        return (item.name, value)
                    },
                    uniquingKeysWith: { _, latest in latest }
                )

                if let oauthError = queryMap["error"] {
                    let msg = queryMap["error_description"] ?? oauthError
                    continuation.resume(throwing: FirebaseAuthError.providerUnavailable(msg))
                    return
                }

                guard queryMap["state"] == pkce.state else {
                    continuation.resume(throwing: FirebaseAuthError.stateMismatch)
                    return
                }

                guard let code = queryMap["code"], !code.isEmpty else {
                    continuation.resume(throwing: FirebaseAuthError.missingAuthorizationCode)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session

            if !session.start() {
                self.webAuthSession = nil
                continuation.resume(throwing: FirebaseAuthError.providerUnavailable("Unable to launch macOS Google sign-in session."))
            }
        }
    }

    func authorizeApple(nonce: AppleSignInNonce) async throws -> (idToken: String, fullName: String?) {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce.sha256Hex

        return try await withCheckedThrowingContinuation { continuation in
            self.appleContinuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding & ASAuthorizationControllerPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let continuation = appleContinuation else { return }
            appleContinuation = nil

            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  !idToken.isEmpty else {
                continuation.resume(throwing: FirebaseAuthError.decodingError("Apple credential did not contain an identity token."))
                return
            }

            var formattedName: String?
            if let fullName = credential.fullName {
                let formatter = PersonNameComponentsFormatter()
                let rendered = formatter.string(from: fullName).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rendered.isEmpty {
                    formattedName = rendered
                }
            }
            continuation.resume(returning: (idToken: idToken, fullName: formattedName))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            guard let continuation = appleContinuation else { return }
            appleContinuation = nil

            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain && nsError.code == ASAuthorizationError.canceled.rawValue {
                continuation.resume(throwing: FirebaseAuthError.cancelled)
                return
            }
            if nsError.code == -7026 || (nsError.domain == ASAuthorizationError.errorDomain && nsError.code == ASAuthorizationError.unknown.rawValue) {
                continuation.resume(throwing: FirebaseAuthError.providerUnavailable(
                    "Sign in with Apple on macOS requires signing BrokBot.app with an Apple Developer Team provisioning profile and the 'Sign in with Apple' capability."
                ))
                return
            }
            continuation.resume(throwing: error)
        }
    }
}
