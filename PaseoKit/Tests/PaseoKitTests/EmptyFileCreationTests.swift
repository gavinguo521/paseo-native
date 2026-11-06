import Testing
@testable import PaseoKit

struct EmptyFileCreationTests {
    @Test func onlyMissingReadErrorsOfferCreation() {
        #expect(EmptyFileCreation.isMissing("ENOENT: no such file or directory, open '/tmp/x'"))
        for error in ["EACCES: permission denied", "连接已断开", "读取超时", "some file called ENOENT:", "", "ENOTDIR: not a directory"] {
            #expect(!EmptyFileCreation.isMissing(error))
        }
    }
    @Test func requestUsesExactRemoteParentAndExclusiveCreateEndpointFields() throws {
        let request = try EmptyFileCreation.request(cwd: "/Users/remote/.secrets", path: "keys.env")
        #expect(request == ["cwd": "/Users/remote/.secrets", "parentPath": ".", "name": "keys.env", "kind": "file"])
        #expect(try EmptyFileCreation.request(cwd: "/tmp", path: "中文 ' $.env")["name"] == "中文 ' $.env")
        #expect(try EmptyFileCreation.request(cwd: "/workspace", path: "src/foo.swift") ==
                ["cwd": "/workspace", "parentPath": "src", "name": "foo.swift", "kind": "file"])
        for name in ["", ".", "..", "../keys", "a/../b", "/a", "a//b", "a\\b", " keys.env", "keys.env ", "x\0y"] {
            #expect(throws: (any Error).self) { try EmptyFileCreation.request(cwd: "/tmp", path: name) }
        }
    }
    @Test func existingFileAndMalformedResponsesAreNeverSuccess() throws {
        try EmptyFileCreation.validate(["payload": ["success": true, "path": "keys.env"]])
        for response: JSONValue in [
            ["payload": ["success": false, "error": "keys.env already exists"]],
            ["payload": ["success": false, "error": "EACCES"]],
            ["payload": [:]], [:]
        ] { #expect(throws: (any Error).self) { try EmptyFileCreation.validate(response) } }
    }
}
