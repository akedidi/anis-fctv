import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Mirrors `com.rblive.common.utils.RBCrypto` + `UrlTools.signPlayUrl` / `encodeStreamTokenA`
/// used by `PPManager.hlsInject` for `/api/stream/detail` playback resolution.
enum RbliveStreamCrypto: Sendable {

    /// Default `AppEnv` STK/STI from `com.rblive.launcher.App` (3.0.319) — same as Android before Firebase overrides.
    private static let embeddedSTKBase64 = "dUU1R2szRnZwTjVqUlF4RHVqdUQzdnVX"
    private static let embeddedSTIBase64 = "dGhaOURIa0RXeGo1SmNwOQ=="

    private static let userDefaultsSTKKey = "fctv.rblive.stk_b64"
    private static let userDefaultsSTIKey = "fctv.rblive.sti_b64"

    /// Fixed AES key/IV for `UrlTools.encodeStreamTokenA` (UTF-8 of these hex/char literals).
    private static let streamTokenKeyUTF8 = "a7981cc9eb2f4d19dcfea57b101ecd89"
    private static let streamTokenIVUTF8 = "8017d3a8f1400d2f"

    // MARK: - STK / STI (ParamsManager.getSTK / getSTI)

    static func materialSTK() throws -> Data {
        let b64 = UserDefaults.standard.string(forKey: userDefaultsSTKKey) ?? embeddedSTKBase64
        return try keyBytesFromMixedConfigBase64(b64)
    }

    static func materialSTI() throws -> Data {
        let b64 = UserDefaults.standard.string(forKey: userDefaultsSTIKey) ?? embeddedSTIBase64
        return try keyBytesFromMixedConfigBase64(b64)
    }

    /// `MixedConfig` stores Base64; `RBCrypto.fromBase64` yields the UTF-8 key/IV string used as raw AES bytes.
    private static func keyBytesFromMixedConfigBase64(_ wrapped: String) throws -> Data {
        guard let decoded = Data(base64Encoded: wrapped) else {
            throw RbliveAPIError.streamCryptoFailed("STK/STI base64 invalide")
        }
        guard let s = String(data: decoded, encoding: .utf8) else {
            throw RbliveAPIError.streamCryptoFailed("STK/STI UTF-8")
        }
        return Data(s.utf8)
    }

    // MARK: - PBDataStreamOriginalInfo (AES-CBC + protobuf)

    /// `RBCrypto.decodeOriginalInfo` — decrypt `PBDataStream.original_info` bytes then parse `PBDataStreamOriginalInfo`.
    static func decryptOriginalInfoWire(_ wire: Data) throws -> RbliveDecodedStreamOriginal {
        let key = try materialSTK()
        let iv = try materialSTI()
        guard iv.count == 16 else {
            throw RbliveAPIError.streamCryptoFailed("STI doit faire 16 octets, a \(iv.count)")
        }
        guard [16, 24, 32].contains(key.count) else {
            throw RbliveAPIError.streamCryptoFailed("STK AES \(key.count) octets invalide")
        }
        let plain = try aesCBCPKCS7Decrypt(cipher: wire, key: key, iv: iv)
        return try RbliveProtobuf.parseDataStreamOriginalInfo(plain)
    }

    // MARK: - viaRB: rot47 + signPlayUrl

    /// Decode obfuscated `PBDataStream.url` (field 4): classic ROT47 then drop first 8 chars.
    /// Returns a bare `https://…` play URL (before `UrlTools.signPlayUrl`).
    static func decodeStreamUrl(_ encoded: String) -> String? {
        let rotated = rot47(encoded)
        guard rotated.count > 8 else { return nil }
        let tail = String(rotated.dropFirst(8))
        guard tail.hasPrefix("http://") || tail.hasPrefix("https://") else { return nil }
        return tail
    }

    /// `PPManager.viaRB` — `rot47(url).substring(from: 8)` then `UrlTools.signPlayUrl`.
    static func signPlayUrlWithRbSession(playUrl: String, rbSession: String) throws -> String {
        guard let decoded = decodeStreamUrl(playUrl) else {
            throw RbliveAPIError.streamCryptoFailed("URL rot47 invalide / trop courte")
        }
        return try signPlayUrl(playUrl: decoded, rbSession: rbSession)
    }

    /// `UrlTools.signPlayUrl`
    static func signPlayUrl(playUrl: String, rbSession: String) throws -> String {
        guard let u = URL(string: playUrl), let host = u.host else {
            throw RbliveAPIError.streamCryptoFailed("URL parse \(playUrl)")
        }
        let prefix = "https://\(host)/"
        let token = try encodeStreamTokenA(rbSession)
        let replacement = "https://\(host)/token-\(token)/"
        guard playUrl.hasPrefix(prefix) else {
            throw RbliveAPIError.streamCryptoFailed("Préfixe host inattendu")
        }
        return playUrl.replacingOccurrences(of: prefix, with: replacement, options: [], range: nil)
    }

    /// `UrlTools.encodeStreamTokenA` — AES/CTR/NoPadding, Base64, strip newlines, percent-encode, trailing `a`.
    private static func encodeStreamTokenA(_ src: String) throws -> String {
        let key = Data(streamTokenKeyUTF8.utf8)
        let iv = Data(streamTokenIVUTF8.utf8)
        let plain = Data(src.utf8)
        let enc = try aesCTREncrypt(data: plain, key: key, iv: iv)
        var b64 = enc.base64EncodedString()
        b64 = b64.replacingOccurrences(of: "\n", with: "")
        b64 = b64.replacingOccurrences(of: "\r\n", with: "")
        b64 = b64.replacingOccurrences(of: "\r", with: "")
        let encoded = uriEncodeAndroidStyle(b64)
        return encoded + "a"
    }

    // MARK: - bruDecode / ROT13 (CDN helpers, parity with Android)

    /// Android `RBCrypto.bruDecode` / CSL param decode: drop 8, URL-decode, ROT13, Base64.
    static func bruDecode(_ s: String) throws -> String {
        guard s.count >= 8 else { throw RbliveAPIError.streamCryptoFailed("bruDecode court") }
        let sub = String(s.dropFirst(8))
        let decoded = try urlFormDecodeUTF8(sub)
        let r13 = rot13(decoded)
        // Base64 may need padding
        var b64 = r13.replacingOccurrences(of: "\n", with: "")
        let pad = (4 - (b64.count % 4)) % 4
        if pad > 0 { b64 += String(repeating: "=", count: pad) }
        guard let b = Data(base64Encoded: b64) else {
            throw RbliveAPIError.streamCryptoFailed("bruDecode base64")
        }
        guard let out = String(data: b, encoding: .utf8) else {
            throw RbliveAPIError.streamCryptoFailed("bruDecode utf8")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rot13(_ str: String) -> String {
        String(str.map { c in
            let u = c.unicodeScalars.first!.value
            if (u >= 65 && u <= 77) || (u >= 97 && u <= 109) { return Character(UnicodeScalar(u + 13)!) }
            if (u >= 78 && u <= 90) || (u >= 110 && u <= 122) { return Character(UnicodeScalar(u - 13)!) }
            return c
        })
    }

    /// Classic ROT47 over printable ASCII (`!`…`~`), shift +47.
    /// Field-4 CDN URLs decode with this (not the Android +14 variant used elsewhere).
    private static func rot47(_ str: String) -> String {
        String(str.map { c in
            let u = c.unicodeScalars.first!.value
            if u >= 33 && u <= 126 {
                let v = Int(u)
                return Character(UnicodeScalar(((v - 33 + 47) % 94) + 33)!)
            }
            return c
        })
    }

    private static func urlFormDecodeUTF8(_ s: String) throws -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        guard let out = plus.removingPercentEncoding else {
            throw RbliveAPIError.streamCryptoFailed("URL decode")
        }
        return out
    }

    /// Path-segment style encoding similar to Android `Uri.encode` for ASCII payload.
    /// Characters in `allowed` are left as-is; everything else (incl. `/` `+` `=`) is percent-encoded.
    private static func uriEncodeAndroidStyle(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - CommonCrypto

    private static func aesCBCPKCS7Decrypt(cipher: Data, key: Data, iv: Data) throws -> Data {
        #if canImport(CommonCrypto)
        var outLength: size_t = 0
        let bufferSize = cipher.count + 16
        var buffer = Data(count: bufferSize)
        let status = buffer.withUnsafeMutableBytes { outBuf in
            cipher.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, cipher.count,
                            outBuf.baseAddress, bufferSize,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw RbliveAPIError.streamCryptoFailed("AES-CBC decrypt status \(status)")
        }
        return buffer.prefix(outLength)
        #else
        throw RbliveAPIError.streamCryptoFailed("CommonCrypto indisponible")
        #endif
    }

    private static func aesCTREncrypt(data: Data, key: Data, iv: Data) throws -> Data {
        #if canImport(CommonCrypto)
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBuf in
            iv.withUnsafeBytes { ivBuf in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBuf.baseAddress,
                    keyBuf.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cry = cryptor else {
            throw RbliveAPIError.streamCryptoFailed("CTR create \(createStatus)")
        }
        defer { CCCryptorRelease(cry) }

        var buf = ContiguousArray<UInt8>(repeating: 0, count: data.count)
        var outLen: size_t = 0
        var finLen: size_t = 0
        let upd: CCCryptorStatus = buf.withUnsafeMutableBufferPointer { bp in
            guard let outBase = bp.baseAddress else { return CCCryptorStatus(kCCParamError) }
            return data.withUnsafeBytes { inBuf in
                guard let inBase = inBuf.baseAddress else { return CCCryptorStatus(kCCParamError) }
                let st = CCCryptorUpdate(cry, inBase, data.count, outBase, data.count, &outLen)
                guard st == kCCSuccess else { return st }
                let tail = outBase.advanced(by: Int(outLen))
                let rem = data.count - Int(outLen)
                return CCCryptorFinal(cry, tail, rem, &finLen)
            }
        }
        guard upd == kCCSuccess else {
            throw RbliveAPIError.streamCryptoFailed("CTR cryptor \(upd)")
        }
        let total = Int(outLen + finLen)
        return Data(buf.prefix(total))
        #else
        throw RbliveAPIError.streamCryptoFailed("CommonCrypto indisponible")
        #endif
    }
}
