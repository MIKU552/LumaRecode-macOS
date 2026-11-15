import Foundation
import XCTest
@testable import LumaCore

final class ProbeParityTests: XCTestCase {
    func testFirstDecodedFrameFillsOnlyMissingStreamColorTags() throws {
        let json = """
        {"format":{"duration":"3"},"streams":[{"codec_type":"video","index":0,"codec_name":"hevc",
          "width":1920,"height":1080,"pix_fmt":"yuv420p10le",
          "color_transfer":"unknown","color_space":"unknown","color_primaries":"unknown"}],
         "frames":[{"color_transfer":"smpte2084","color_space":"bt2020nc",
           "color_primaries":"bt2020","color_range":"tv"}]}
        """
        let result = try MediaProbe.parse(Data(json.utf8), url: URL(fileURLWithPath: "/tmp/sample.mp4"))
        XCTAssertEqual(result.sourceColor, .pq)
        XCTAssertEqual(result.transfer, "smpte2084")
        XCTAssertEqual(result.primaries, "bt2020")
        XCTAssertEqual(result.matrix, "bt2020nc")
        XCTAssertEqual(result.colorRange, "tv")
    }

    func testTrustedStreamTagsWinOverFrameFallback() throws {
        let json = """
        {"streams":[{"codec_type":"video","codec_name":"hevc","width":1920,"height":1080,
            "color_transfer":"arib-std-b67","color_primaries":"bt2020","color_space":"bt2020nc",
            "pix_fmt":"p010le"}],
         "frames":[{"color_transfer":"smpte2084","color_primaries":"bt709"}]}
        """
        let result = try MediaProbe.parse(Data(json.utf8), url: URL(fileURLWithPath: "/tmp/input.mp4"))
        XCTAssertEqual(result.sourceColor, .hlg)
        XCTAssertEqual(result.transfer, "arib-std-b67")
        XCTAssertEqual(result.primaries, "bt2020")
    }

    func testCoverArtworkIsNotSelectedAsVideo() throws {
        let json = """
        {"streams":[
          {"codec_type":"video","codec_name":"mjpeg","width":400,"height":300,
           "disposition":{"attached_pic":1},"pix_fmt":"yuvj420p"},
          {"codec_type":"video","codec_name":"hevc","width":3840,"height":2160,
           "disposition":{"attached_pic":0},"color_transfer":"smpte2084",
           "color_primaries":"bt2020","color_space":"bt2020nc","pix_fmt":"yuv420p10le"}]}
        """
        let result = try MediaProbe.parse(Data(json.utf8), url: URL(fileURLWithPath: "/tmp/movie.mp4"))
        XCTAssertEqual(result.codec, "hevc")
        XCTAssertEqual(result.width, 3840)
        XCTAssertEqual(result.sourceColor, .pq)
    }

    func testFirstFrameDynamicHDREvidenceBlocksArchive() throws {
        let json = """
        {"streams":[{"codec_type":"video","codec_name":"hevc","width":160,"height":90,
         "color_transfer":"smpte2084","color_primaries":"bt2020",
         "color_space":"bt2020nc","pix_fmt":"yuv420p10le"}],
         "frames":[{"side_data_list":[{"side_data_type":"HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"}]}]}
        """
        let info = try MediaProbe.parse(Data(json.utf8), url: URL(fileURLWithPath: "/tmp/input.mp4"))
        XCTAssertTrue(info.dynamicHDR)
        XCTAssertThrowsError(try VideoOutputPolicy.resolve(info, selection: EncodeSelection()))
    }
}
