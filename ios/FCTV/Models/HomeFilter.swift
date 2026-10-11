import Foundation
import SwiftUI

/// Mirrors `com.rblive.common.model.enums.HomeFilter` from the source.
enum HomeFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case live
    case finished

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .live: return "Live"
        case .finished: return "Finished"
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable, Hashable {
    case overview, lineups, stats, h2h

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "Overview"
        case .lineups: return "Lineups"
        case .stats: return "Stats"
        case .h2h: return "H2H"
        }
    }
}
