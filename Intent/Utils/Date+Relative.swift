import Foundation

extension Date {
    var relativeFormatted: String {
        let interval = Date().timeIntervalSince(self)
        if interval < Constants.RelativeTime.minute { return "now" }
        if interval < Constants.RelativeTime.hour {
            return "\(Int(interval / Constants.RelativeTime.minute))m"
        }
        if interval < Constants.RelativeTime.day {
            return "\(Int(interval / Constants.RelativeTime.hour))h"
        }
        if interval < Constants.RelativeTime.week {
            return "\(Int(interval / Constants.RelativeTime.day))d"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: self)
    }
}
