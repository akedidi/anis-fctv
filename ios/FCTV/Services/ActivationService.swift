import Foundation

/// Calls `/api/activation/verify` with the same JSON envelope as the Android `PaymentRepository`.
struct ActivationService {
    enum Result: Equatable {
        case success
        case invalid(String)
        case empty
    }

    func validate(_ code: String) async -> Result {
        let normalized = code
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .empty }

        let deviceId = await RbliveHTTPClient.shared.stableDeviceId()
        let body = ActivationVerifyDataParams(
            data: ActivationVerifyParams(deviceId: deviceId, activationCode: normalized, brand: "77")
        )
        let enc = JSONEncoder()
        guard let json = try? enc.encode(body) else {
            return .invalid("Encodage JSON impossible")
        }

        do {
            let data = try await RbliveHTTPClient.shared.postJSON(path: "/api/activation/verify", jsonBody: json)
            let meta = RbliveProtobuf.parsePBResponseCodeAndMessage(data)
            if let c = meta.code, c != 0 {
                return .invalid(meta.message ?? "Code \(c)")
            }
            return .success
        } catch let e as RbliveAPIError {
            if case let .http(_, body) = e, let raw = body?.data(using: .utf8) {
                let meta = RbliveProtobuf.parsePBResponseCodeAndMessage(raw)
                return .invalid(meta.message ?? "Activation refusée")
            }
            return .invalid(e.localizedDescription)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

}

private struct ActivationVerifyParams: Codable {
    let deviceId: String
    let activationCode: String
    let brand: String
}

private struct ActivationVerifyDataParams: Codable {
    let data: ActivationVerifyParams
}
