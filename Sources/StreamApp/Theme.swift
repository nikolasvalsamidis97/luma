import SwiftUI

enum Theme {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.085)
    static let sidebar = Color(red: 0.075, green: 0.086, blue: 0.108)
    static let panel = Color(red: 0.10, green: 0.115, blue: 0.14)
    static let accent = Color(red: 1, green: 0.40, blue: 0.31)
    static let muted = Color(red: 0.53, green: 0.57, blue: 0.63)
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill").font(.system(size: 27, weight: .medium)).foregroundStyle(Theme.accent)
            Text("luma").font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-1)
        }
    }
}
