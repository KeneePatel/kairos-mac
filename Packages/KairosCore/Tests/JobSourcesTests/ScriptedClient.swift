import Foundation
import TestSupport

@testable import JobSources

extension ScriptedURLProtocol {
    /// A source HTTP client whose requests only this script can answer.
    static func client(_ replies: [String: Reply], userAgent: String = "Kairos-tests") -> (URLSessionHTTPClient, Script)
    {
        let (configuration, script) = configuration(replies)
        return (URLSessionHTTPClient(configuration: configuration, userAgent: userAgent), script)
    }
}
