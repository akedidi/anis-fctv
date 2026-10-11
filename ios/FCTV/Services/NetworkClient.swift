import Alamofire
import Foundation

/// Client HTTP minimal (Alamofire / équivalent OkHttp Android).
/// Utilisez-le pour les appels REST quand vous remplacerez les données mock.
enum NetworkClient {
    static func fetchData(from url: URL) async throws -> Data {
        try await AF.request(url)
            .validate()
            .serializingData()
            .value
    }
}
