import Kingfisher
import SwiftUI

/// Kingfisher image configured for rblive logo CDNs (Referer / UA required).
struct RemoteLogo: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 0
    var contentMode: SwiftUI.ContentMode = .fit

    private static let modifier = AnyModifier { request in
        var req = request
        req.setValue(
            "rbapp/--dg-snd-app-33/3.3.0/ios/FCTV33",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("https://www.rbtv77.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://www.rbtv77.com", forHTTPHeaderField: "Origin")
        return req
    }

    var body: some View {
        Group {
            if let url {
                KFImage.url(url)
                    .requestModifier(Self.modifier)
                    .fade(duration: 0.15)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
