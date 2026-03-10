import Foundation
import UIKit
import Combine

class APIService: ObservableObject {
    private let baseURL = "https://bootiak.org"
    private let auth: AuthService

    /// The currently selected project. Set by ProjectPickerView; persisted in UserDefaults.
    @Published var currentProject: Project? {
        didSet {
            UserDefaults.standard.set(currentProject?.projectID, forKey: "currentProjectID")
        }
    }

    init(auth: AuthService) {
        self.auth = auth
        // Restore last-used project ID — validated on first API call
        if let saved = UserDefaults.standard.string(forKey: "currentProjectID") {
            // We store just the ID here; the full Project object is fetched in ProjectPickerView
            currentProject = Project(projectID: saved, name: "", createdBy: "", createdAt: "")
        }
    }

    // MARK: - Core request

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(auth.accessToken ?? "")", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        var (data, response) = try await URLSession.shared.data(for: req)

        if (response as? HTTPURLResponse)?.statusCode == 401 {
            if await auth.refreshAccessToken() {
                req.setValue("Bearer \(auth.accessToken ?? "")", forHTTPHeaderField: "Authorization")
                (data, response) = try await URLSession.shared.data(for: req)
            } else {
                await MainActor.run { auth.logout() }
                throw APIError.unauthorized
            }
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let data = try await request(path, method: method, body: body)
        return try JSONDecoder().decode(type, from: data)
    }

    private var projectPath: String {
        guard let pid = currentProject?.projectID else { return "" }
        return "/api/projects/\(pid.urlEncoded)"
    }

    // MARK: - Projects

    func listProjects() async throws -> [Project] {
        return try await decode([Project].self, path: "/api/projects")
    }

    func createProject(name: String) async throws -> Project {
        return try await decode(Project.self, path: "/api/projects", method: "POST", body: ["name": name])
    }

    func getProject(projectID: String) async throws -> Project {
        return try await decode(Project.self, path: "/api/projects/\(projectID.urlEncoded)")
    }

    func addMember(projectID: String, email: String) async throws -> ProjectMember {
        return try await decode(ProjectMember.self, path: "/api/projects/\(projectID.urlEncoded)/members", method: "POST", body: ["email": email])
    }

    func removeMember(projectID: String, userID: String) async throws {
        _ = try await request("/api/projects/\(projectID.urlEncoded)/members/\(userID.urlEncoded)", method: "DELETE")
    }

    // MARK: - Parts

    func listParts(query: String = "") async throws -> [Part] {
        let path = query.isEmpty
            ? "\(projectPath)/parts"
            : "\(projectPath)/parts?q=\(query.urlEncoded)"
        return try await decode([Part].self, path: path)
    }

    func createPart(partNum: String, partName: String, category: String?, drawerID: String?, notes: String?, aiDescription: String?) async throws -> Part {
        var body: [String: Any] = ["part_num": partNum, "part_name": partName]
        if let v = category { body["category"] = v }
        if let v = drawerID { body["drawer_id"] = v }
        if let v = notes { body["notes"] = v }
        if let v = aiDescription { body["ai_description"] = v }
        return try await decode(Part.self, path: "\(projectPath)/parts", method: "POST", body: body)
    }

    func updatePart(partNum: String, partName: String? = nil, category: String? = nil, drawerID: String? = nil, notes: String? = nil) async throws -> Part {
        var body: [String: Any] = [:]
        if let v = partName { body["part_name"] = v }
        if let v = category { body["category"] = v }
        if let v = drawerID { body["drawer_id"] = v }
        if let v = notes { body["notes"] = v }
        return try await decode(Part.self, path: "\(projectPath)/parts/\(partNum.urlEncoded)", method: "PUT", body: body)
    }

    // MARK: - Drawers

    func listDrawers() async throws -> [Drawer] {
        return try await decode([Drawer].self, path: "\(projectPath)/drawers")
    }

    func createDrawer(cabinet: Int, row: String, col: Int, label: String?, notes: String?) async throws -> Drawer {
        var body: [String: Any] = ["cabinet": cabinet, "row": row, "col": col]
        if let v = label { body["label"] = v }
        if let v = notes { body["notes"] = v }
        return try await decode(Drawer.self, path: "\(projectPath)/drawers", method: "POST", body: body)
    }

    func getDrawerParts(drawerID: String) async throws -> DrawerWithParts {
        return try await decode(DrawerWithParts.self, path: "\(projectPath)/drawers/\(drawerID)/parts")
    }

    // MARK: - Identify

    func getUploadURL(contentType: String = "image/jpeg") async throws -> UploadResponse {
        return try await decode(UploadResponse.self, path: "/api/images/upload", method: "POST", body: ["content_type": contentType])
    }

    func uploadImageToS3(url: String, data: Data) async throws {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "PUT"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError("Image upload failed")
        }
    }

    func identify(s3Key: String) async throws -> IdentifyResponse {
        return try await decode(IdentifyResponse.self, path: "\(projectPath)/identify", method: "POST", body: ["s3_key": s3Key])
    }

    func lookupPart(_ partNum: String) async throws -> LookupResponse {
        return try await decode(LookupResponse.self, path: "\(projectPath)/lookup/\(partNum.urlEncoded)")
    }

    // MARK: - Catalog

    func catalogSearch(query: String) async throws -> [CatalogPart] {
        guard query.count >= 2 else { return [] }
        return try await decode([CatalogPart].self, path: "/api/catalog/search?q=\(query.urlEncoded)")
    }

    func catalogStatus() async throws -> CatalogStatus {
        return try await decode(CatalogStatus.self, path: "/api/catalog/status")
    }

    func loadCatalog() async throws -> Int {
        let data = try await request("/api/catalog/load", method: "POST")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["parts_loaded"] as? Int ?? 0
    }

    // MARK: - AI Models

    func listModels() async throws -> ModelsResponse {
        return try await decode(ModelsResponse.self, path: "/api/models")
    }

    func setModel(_ modelID: String) async throws {
        _ = try await request("/api/settings", method: "PUT", body: ["model_id": modelID])
    }

    // MARK: - Export / Import

    func exportCatalog() async throws -> Data {
        return try await request("\(projectPath)/export")
    }

    func importCatalog(_ jsonData: Data) async throws -> (parts: Int, drawers: Int) {
        guard let url = URL(string: baseURL + "\(projectPath)/import") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(auth.accessToken ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["parts"] as? Int ?? 0, json?["drawers"] as? Int ?? 0)
    }

    // MARK: - Image helpers

    func compressImage(_ image: UIImage, maxBytes: Int = 4 * 1024 * 1024) -> Data {
        var quality: CGFloat = 0.85
        var data = image.jpegData(compressionQuality: quality) ?? Data()
        while data.count > maxBytes && quality > 0.3 {
            quality -= 0.15
            data = image.jpegData(compressionQuality: quality) ?? Data()
        }
        return data
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case invalidURL
        case unauthorized
        case noProject
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .unauthorized: return "Session expired. Please log in again."
            case .noProject: return "No project selected."
            case .serverError(let msg): return msg
            }
        }
    }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
