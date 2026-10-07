import Foundation

/// Typed access to the Blueprints API (`/blueprints/v1/...`).
nonisolated struct BlueprintService: Sendable {
    struct Page: Sendable {
        var results: [BlueprintOverview]
        var totalCount: Int?
        /// Result items that could not be parsed (for example, missing an id).
        var unparseableCount: Int
    }

    let client: PlatformAPIClient
    private let basePath = "/blueprints/v1/blueprints"

    init(client: PlatformAPIClient) {
        self.client = client
    }

    /// GET /v1/blueprints. `page` is zero-based.
    func listPage(
        page: Int = 0,
        pageSize: Int = 100,
        search: String? = nil,
        sort: String = "created:desc"
    ) async throws -> Page {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page-size", value: String(pageSize)),
            URLQueryItem(name: "sort", value: sort),
        ]
        if let search, !search.isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        let response = try await client.send(method: "GET", path: basePath, query: query)
        let json: JSONValue
        do {
            json = try JSONValue(data: response.data)
        } catch {
            throw APIError.invalidResponse("Blueprint list is not valid JSON: \(error.localizedDescription)")
        }
        guard let items = json["results"]?.arrayValue else {
            throw APIError.invalidResponse("Blueprint list has no \"results\" array.")
        }
        let parsed = items.compactMap(BlueprintOverview.init(json:))
        return Page(
            results: parsed,
            totalCount: json["totalCount"]?.numberValue?.intValue,
            unparseableCount: items.count - parsed.count
        )
    }

    /// Pages through every blueprint.
    func listAll(search: String? = nil, pageSize: Int = 100) async throws -> [BlueprintOverview] {
        var all: [BlueprintOverview] = []
        var page = 0
        while true {
            try Task.checkCancellation()
            let result = try await listPage(page: page, pageSize: pageSize, search: search)
            all.append(contentsOf: result.results)
            let received = result.results.count + result.unparseableCount
            let reachedTotal = result.totalCount.map { (page + 1) * pageSize >= $0 } ?? false
            if received < pageSize || reachedTotal || received == 0 { break }
            page += 1
            // Hard stop in case the server ignores paging.
            if page >= 1000 { break }
        }
        return all
    }

    /// GET /v1/blueprints/{id}.
    func detail(id: String) async throws -> BlueprintDetail {
        let response = try await client.send(method: "GET", path: "\(basePath)/\(Self.escape(id))")
        do {
            return try BlueprintDetail(data: response.data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.invalidResponse("Blueprint \(id) is not valid JSON: \(error.localizedDescription)")
        }
    }

    /// PATCH /v1/blueprints/{id} with `{"steps": [...]}` as merge-patch JSON.
    /// `steps` must be the complete array: merge-patch replaces arrays wholesale.
    /// Only `steps` is sent; divisionId is never sent.
    func patchSteps(id: String, steps: JSONValue) async throws {
        guard steps.arrayValue != nil else {
            throw APIError.invalidResponse("Refusing to PATCH: steps is not an array.")
        }
        let body = JSONValue.object(JSONObject(["steps": steps])).serialized()
        _ = try await client.send(
            method: "PATCH",
            path: "\(basePath)/\(Self.escape(id))",
            body: body,
            contentType: "application/merge-patch+json"
        )
    }

    /// POST /v1/blueprints/{id}/deploy. Expects 202. Only retried on 429, so a
    /// deployment is never started twice.
    func deploy(id: String) async throws {
        _ = try await client.send(
            method: "POST",
            path: "\(basePath)/\(Self.escape(id))/deploy",
            retryPolicy: .rateLimitOnly
        )
    }

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}
