import Foundation
import StreamCore

extension StreamCoreChecks {
    func testMediaTraits() throws {
        precondition(MediaTraits.from(name: "4K-A+ - Silo (2023)").resolution == "4K")
        precondition(MediaTraits.from(name: "Film [1080p] [MULTI-SUB]") == MediaTraits(resolution: "1080p", multipleSubtitles: true))
        precondition(MediaTraits.from(name: "UHD Film MULTISUB").multipleSubtitles)
        precondition(MediaTraits.from(name: "Film FHD").resolution == "1080p")
        for name in ["Film MULTI AUDIO", "4Kids", "1080Pixels", "MSUBmarine", "Multisubmarine", "Film HD"] {
            precondition(MediaTraits.from(name: name) == MediaTraits(), "False badge for \(name)")
        }
        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"video":{"width":"3840","height":1600},"subtitles":[{"language":"en"},{"language":"sv"}]}"#.utf8))
        precondition(MediaTraits.from(name: "Film", metadata: metadata) == MediaTraits(resolution: "4K", multipleSubtitles: true))
        precondition(MediaTraits.resolution(width: 7680, height: 4320) == nil, "Do not call 8K 4K")
        let series = MediaItem(streamID: "1", kind: .series, name: "Series")
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"episodes":{"1":[{"id":1,"info":{"video":{"width":1920,"height":1080},"subtitle_count":2}},{"id":2}]}}"#.utf8))
        let details = try SeriesDetails.parse(json, series: series)
        precondition(details.episodes[0].traits == MediaTraits(resolution: "1080p", multipleSubtitles: true))
        precondition(details.traits == MediaTraits(), "Do not label the entire series from just one episode")
    }
    func testHLSQualities() {
        let manifest = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo, RESOLUTION=999x999",URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100,CODECS="avc1,mp4a",RESOLUTION=1920x1080,AUDIO="audio"
        high.m3u8?token=abc
        #EXT-X-STREAM-INF:BANDWIDTH=50,RESOLUTION=1280x720
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=90,RESOLUTION=1920x1080
        alternate.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,RESOLUTION=3840x2160,URI="iframe.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=10
        audio.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=99,NAME="Film,RESOLUTION=123x123",RESOLUTION=-1x20
        malformed.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=200,RESOLUTION=3840x2160
        """
        precondition(HLSQualityDiscovery.resolutions(in: manifest) == [VideoResolution(width: 1280, height: 720), VideoResolution(width: 1920, height: 1080)])
        precondition(HLSQualityDiscovery.resolutions(in: "#EXTM3U\n#EXTINF:10,\nvideo.ts").isEmpty)
        precondition(HLSQualityDiscovery.resolutions(in: "<html>provider error</html>").isEmpty)
        precondition(!HLSQualityDiscovery.supports(URL(string: "https://example.test/video.mp4")!))
        precondition(HLSQualityDiscovery.supports(URL(string: "https://example.test/play?output=m3u8")!))
    }
}
