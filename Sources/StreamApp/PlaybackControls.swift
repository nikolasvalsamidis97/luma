import SwiftUI
import StreamCore

struct AudioTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}
struct PlaybackQuality: Identifiable, Equatable {
    let id: String
    let label: String
    let resolution: VideoResolution
    let videoTrackID: Int32?
}

struct AudioControls: View {
    @ObservedObject var player: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Audio", systemImage: "waveform").font(.headline)
            if player.audioTracks.isEmpty {
                Text(player.buffering ? "Looking for audio tracks…" : "No audio tracks available.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Track", selection: Binding(get: { player.selectedAudio }, set: { player.selectAudio($0) })) {
                    if player.selectedAudio == -1 { Text("No track selected").tag(Int32(-1)) }
                    ForEach(player.audioTracks) { track in Text(track.name).tag(track.id) }
                }.pickerStyle(.menu).accessibilityLabel("Audio track")
                Text("\(player.audioTracks.count) \(player.audioTracks.count == 1 ? "track" : "tracks") in this video")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 300)
    }
}

struct QualityControls: View {
    @ObservedObject var player: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Quality", systemImage: "slider.horizontal.3").font(.headline)
            ScrollView {
                VStack(spacing: 6) {
                    if player.hasAdaptiveQualities { qualityButton("Auto", id: "auto") }
                    ForEach(player.qualities) { quality in qualityButton(quality.label, id: quality.id) }
                }
            }.frame(maxHeight: 240)
            Text(player.hasAdaptiveQualities ? "Uses the best stream up to your chosen resolution. Switching briefly reconnects." : "Switches between the video tracks supplied with this video.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 260)
    }
    private func qualityButton(_ label: String, id: String) -> some View {
        Button { player.selectQuality(id) } label: {
            HStack {
                Text(label); Spacer()
                if player.selectedQualityID == id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }.padding(10).contentShape(Rectangle())
                .background(player.selectedQualityID == id ? Theme.accent.opacity(0.12) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel("\(label) quality")
    }
}
