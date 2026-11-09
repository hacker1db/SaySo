import Foundation

enum DictationStatistics {
    static func savedSeconds(words: Int, seconds: Double) -> Double {
        max(0, Double(words) / 40 * 60 - seconds)
    }
}
