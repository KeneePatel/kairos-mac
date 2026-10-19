import Foundation

/// One of your public repos, as GitHub's REST API describes it.
public struct GitHubRepo: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let fullName: String
    public let description: String?
    public let language: String?
    public let fork: Bool
    public let archived: Bool
    public let stargazersCount: Int
    public let htmlUrl: URL
    public let createdAt: Date
    public let pushedAt: Date?
    public let topics: [String]?

    public var id: String { fullName }
}

public enum GitHubError: Error, Equatable, Sendable {
    case noProfile
    case userNotFound(String)
    /// 60 requests an hour without a token.
    case rateLimited
    case tokenRejected
    case http(Int)
    case network(String)
}

/// Reads public repos through GitHub's REST API. A token (from the Keychain) is optional; without
/// one GitHub allows 60 requests an hour, which covers a listing and a few READMEs.
public struct GitHubClient: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let token: String?
    private let send: Send

    public init(token: String?, send: @escaping Send = GitHubClient.urlSession) {
        self.token = token?.isEmpty == false ? token : nil
        self.send = send
    }

    public static let urlSession: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// "https://github.com/jrivera" → "jrivera", using the same rules as validation.
    public static func user(fromProfile url: String?) -> String? {
        guard let url, let profile = Validator.gitHubProfile(url) else { return nil }
        return String(profile.dropFirst("https://github.com/".count))
    }

    /// Your own repos, most recently pushed first, with forks and archived ones at the end.
    public func repos(of user: String) async throws(GitHubError) -> [GitHubRepo] {
        let data = try await get("users/\(user)/repos?per_page=100&sort=pushed&type=owner", user: user)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        guard let repos = try? decoder.decode([GitHubRepo].self, from: data) else { throw .http(200) }
        return repos.filter { !$0.fork && !$0.archived } + repos.filter { $0.fork || $0.archived }
    }

    /// Languages by size, largest first.
    public func languages(of repo: GitHubRepo) async throws(GitHubError) -> [String] {
        let data = try await get("repos/\(repo.fullName)/languages", user: nil)
        guard let bytes = try? JSONDecoder().decode([String: Int].self, from: data) else { return [] }
        return bytes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The README's text, or nil if there is none.
    public func readme(of repo: GitHubRepo) async throws(GitHubError) -> String? {
        do {
            let data = try await get("repos/\(repo.fullName)/readme", user: nil, accept: "application/vnd.github.raw")
            return String(decoding: data, as: UTF8.self)
        } catch .userNotFound {
            return nil
        }
    }

    private func get(_ path: String, user: String?, accept: String = "application/vnd.github+json")
        async throws(GitHubError) -> Data
    {
        guard let url = URL(string: "https://api.github.com/" + path) else { throw .http(0) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Kairos (+https://github.com/KeneePatel/kairos-mac)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw .network(error.localizedDescription)
        }
        switch response.statusCode {
        case 200: return data
        case 401: throw .tokenRejected
        case 403 where response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0", 429: throw .rateLimited
        case 404: throw .userNotFound(user ?? path)
        default: throw .http(response.statusCode)
        }
    }
}
