import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StreamCore

struct SubtitleTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}

struct SubtitleControls: View {
    @ObservedObject var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SubtitleAppearance
    init(player: PlayerModel) {
        self.player = player
        _draft = State(initialValue: player.subtitleAppearance)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Subtitles", systemImage: "captions.bubble").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close subtitles")
            }
            Picker("Track", selection: Binding(get: { player.selectedSubtitle }, set: { player.selectSubtitle($0) })) {
                Text("Off").tag(Int32(-1))
                ForEach(player.subtitleTracks) { Text($0.name).tag($0.id) }
            }
            if player.subtitleTracks.isEmpty { Text("No subtitle tracks found yet. You can add a subtitle file.").font(.caption).foregroundStyle(.secondary) }
            Button { player.chooseSubtitleFile() } label: { Label("Add subtitle file…", systemImage: "plus") }.buttonStyle(.borderless)
            if let error = player.subtitleError { Text(error).font(.caption).foregroundStyle(Theme.accent) }
            Divider()
            HStack {
                Text("Delay")
                Spacer()
                Button { player.setSubtitleDelay(player.subtitleDelay - 0.1) } label: { Image(systemName: "minus") }.help("Show subtitles 0.1 seconds earlier")
                TextField("Seconds", value: Binding(get: { player.subtitleDelay }, set: { player.setSubtitleDelay($0) }), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 65).accessibilityLabel("Subtitle delay in seconds")
                Text("s").foregroundStyle(.secondary)
                Button { player.setSubtitleDelay(player.subtitleDelay + 0.1) } label: { Image(systemName: "plus") }.help("Show subtitles 0.1 seconds later")
                Button("Reset") { player.setSubtitleDelay(0) }.buttonStyle(.borderless)
            }.font(.callout)
            Text("Positive = later · Negative = earlier").font(.caption2).foregroundStyle(.secondary)
            Divider()
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.18, green: 0.25, blue: 0.3), Color(red: 0.08, green: 0.12, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("Your subtitles, your way.")
                    .font(.system(size: 13 * draft.size / 100, weight: .medium))
                    .foregroundStyle(color(draft.textColor)).multilineTextAlignment(.center)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(color(draft.backgroundColor).opacity(draft.backgroundOpacity / 100), in: RoundedRectangle(cornerRadius: 3))
                    .padding(.horizontal, 10).padding(.bottom, 10 + draft.verticalOffset / 6)
            }.frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityLabel("Subtitle appearance preview")
            settingSlider("Size", value: $draft.size, range: 50...200, step: 5, suffix: "%")
            HStack {
                ColorPicker("Text color", selection: colorBinding(\.textColor), supportsOpacity: false)
                Spacer(minLength: 24)
                ColorPicker("Background", selection: colorBinding(\.backgroundColor), supportsOpacity: false)
            }.font(.callout)
            settingSlider("Background opacity", value: $draft.backgroundOpacity, range: 0...100, step: 5, suffix: "%")
            settingSlider("Position · raise from bottom", value: $draft.verticalOffset, range: 0...360, step: 10, suffix: " px")
            Text("Appearance applies to text subtitles. Image subtitles and embedded styling may limit changes.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Defaults") { draft = SubtitleAppearance() }.buttonStyle(.borderless)
                Spacer()
                Button("Apply style") { player.applySubtitleAppearance(draft); draft = player.subtitleAppearance }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(draft == player.subtitleAppearance)
            }
            Text("Applying a style briefly reloads the stream. Movies resume where possible; live TV reconnects to live.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 370).background(Theme.panel).foregroundStyle(.white).tint(Theme.accent)
    }
    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(spacing: 6) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue))\(suffix)").monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
    private func color(_ hex: UInt32) -> Color { Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
    private func colorBinding(_ key: WritableKeyPath<SubtitleAppearance, UInt32>) -> Binding<Color> {
        Binding(get: { color(draft[keyPath: key]) }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            func byte(_ channel: CGFloat) -> UInt32 { UInt32((min(1, max(0, channel)) * 255).rounded()) }
            draft[keyPath: key] = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
        })
    }
}
