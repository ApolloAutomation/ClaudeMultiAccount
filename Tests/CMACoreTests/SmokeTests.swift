import Foundation
import Testing
@testable import CMACore

@Test func pathsAreInjected() {
    let p = AppPaths(home: URL(filePath: "/tmp/h"))
    #expect(p.appSupport.path == "/tmp/h/Library/Application Support/Claude Multi Account")
}
