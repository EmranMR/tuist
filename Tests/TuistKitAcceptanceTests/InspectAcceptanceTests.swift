import Foundation
import TuistAcceptanceTesting
import XCTest
import TuistCore
@testable import TuistKit

final class LintAcceptanceTests: TuistAcceptanceTestCase {
    func test_ios_app_with_headers() async throws {
        try await setUpFixture(.iosAppWithHeaders)
        try await run(InspectImplicitImportsCommand.self)
        XCTAssertStandardOutput(pattern: "We did not find any implicit dependencies in your project.")
    }

    func test_ios_app_with_implicit_dependencies() async throws {
        try await setUpFixture(.iosAppWithImplicitDependencies)
        await XCTAssertThrowsSpecific(try await run(InspectImplicitImportsCommand.self), LintingError())
        XCTAssertStandardOutput(pattern: """
The following implicit dependencies were found:
 - FrameworkA implicitly depends on: FrameworkB
""")

//        catch let error as InspectImplicitImportsServiceError {
//            XCTAssertEqual(
//                error.description,
//                """
//                The following implicit dependencies were found:
//                 - FrameworkA implicitly depends on: FrameworkB
//                """
//            )
//        }
    }
}
