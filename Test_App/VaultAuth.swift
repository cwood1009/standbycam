import Foundation
import LocalAuthentication

enum VaultAuthError: Error {
    case faceIDNotAvailable
    case authFailed
}

struct VaultAuth {
    static func authenticate(completion: @escaping (Result<Void, VaultAuthError>) -> Void) {
        let context = LAContext()
        context.localizedReason = "Unlock Vault"
        context.localizedFallbackTitle = "" // hides "Enter Passcode"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            DispatchQueue.main.async { completion(.failure(.faceIDNotAvailable)) }
            return
        }

        if #available(iOS 11.0, *), context.biometryType != .faceID {
            DispatchQueue.main.async { completion(.failure(.faceIDNotAvailable)) }
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Vault") { success, _ in
            DispatchQueue.main.async {
                success ? completion(.success(())) : completion(.failure(.authFailed))
            }
        }
    }
}
