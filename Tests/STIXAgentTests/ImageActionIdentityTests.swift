import XCTest
@testable import STIXAgent

final class ImageActionIdentityTests: XCTestCase {
    func testRepeatedLastImageEditIsRecognizedDespiteChangedOptionalArguments() {
        let first: JSONValue = .object(["prompt": .string("blue mug"), "input_image": .string("last"), "count": .number(1)])
        let repeated: JSONValue = .object(["prompt": .string("blue mug"), "input_image": .string("last"), "width": .number(512)])
        XCTAssertEqual(ImageActionIdentity.key(first), ImageActionIdentity.key(repeated))
        XCTAssertNotEqual(ImageActionIdentity.key(first), ImageActionIdentity.key(.object(["prompt": .string("red mug"), "input_image": .string("last")])))
        XCTAssertNotEqual(ImageActionIdentity.key(first), ImageActionIdentity.key(.object(["prompt": .string("blue mug"), "input_image": .string("/tmp/other.png")])))
        XCTAssertNil(ImageActionIdentity.key(.object(["prompt": .string("blue mug"), "resize_only": .bool(true)])))
    }
}
