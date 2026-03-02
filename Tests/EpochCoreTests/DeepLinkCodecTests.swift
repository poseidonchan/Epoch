import XCTest
@testable import EpochCore

final class DeepLinkCodecTests: XCTestCase {
    func testArtifactRouteRoundTrip() {
        let projectID = UUID()
        let path = "figures/umap.png"
        let url = DeepLinkCodec.artifactURL(projectID: projectID, path: path)

        guard case let .artifact(parsedProjectID, parsedPath) = DeepLinkCodec.parse(url: url) else {
            return XCTFail("Expected artifact deep link")
        }

        XCTAssertEqual(parsedProjectID, projectID)
        XCTAssertEqual(parsedPath, path)
    }

    func testRunRouteRoundTrip() {
        let projectID = UUID()
        let runID = UUID()
        let url = DeepLinkCodec.runURL(projectID: projectID, runID: runID)

        guard case let .run(parsedProjectID, parsedRunID) = DeepLinkCodec.parse(url: url) else {
            return XCTFail("Expected run deep link")
        }

        XCTAssertEqual(parsedProjectID, projectID)
        XCTAssertEqual(parsedRunID, runID)
    }
}
