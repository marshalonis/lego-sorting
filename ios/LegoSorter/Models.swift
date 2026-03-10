import Foundation

// MARK: - Projects

struct Project: Codable, Identifiable {
    let projectID: String
    let name: String
    let createdBy: String
    let createdAt: String
    var members: [ProjectMember]?

    var id: String { projectID }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case name
        case createdBy = "created_by"
        case createdAt = "created_at"
        case members
    }
}

struct ProjectMember: Codable, Identifiable {
    let projectID: String
    let userID: String
    let email: String
    let addedAt: String

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case userID = "user_id"
        case email
        case addedAt = "added_at"
    }
}

// MARK: - Auth

struct CognitoConfig: Codable {
    let userPoolID: String
    let clientID: String
    let region: String

    enum CodingKeys: String, CodingKey {
        case userPoolID = "user_pool_id"
        case clientID = "client_id"
        case region
    }
}

// MARK: - Parts

struct Part: Codable, Identifiable {
    let partNum: String
    let partName: String
    let category: String?
    let drawerID: String?
    let cabinet: Int?
    let row: String?
    let col: Int?
    let notes: String?

    var id: String { partNum }

    var locationDisplay: String? {
        guard let cabinet, let row, let col else { return nil }
        return "Cabinet \(cabinet) · \(row)\(col)"
    }

    var brickArchitectImageURL: URL? {
        URL(string: "https://brickarchitect.com/content/parts-large/\(partNum).png")
    }

    enum CodingKeys: String, CodingKey {
        case partNum = "part_num"
        case partName = "part_name"
        case category
        case drawerID = "drawer_id"
        case cabinet, row, col, notes
    }
}

// MARK: - Drawers

struct Drawer: Codable, Identifiable {
    let id: String
    let cabinet: Int
    let row: String
    let col: Int
    let label: String?
    let notes: String?
    let partCount: Int
    let firstPartNum: String?

    var displayLabel: String { "\(cabinet)-\(row)\(col)" }

    var firstPartImageURL: URL? {
        guard let num = firstPartNum else { return nil }
        return URL(string: "https://brickarchitect.com/content/parts-large/\(num).png")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cabinet = try c.decode(Int.self, forKey: .cabinet)
        row = try c.decode(String.self, forKey: .row)
        col = try c.decode(Int.self, forKey: .col)
        label = try? c.decode(String.self, forKey: .label)
        notes = try? c.decode(String.self, forKey: .notes)
        partCount = (try? c.decode(Int.self, forKey: .partCount)) ?? 0
        firstPartNum = try? c.decode(String.self, forKey: .firstPartNum)
    }

    enum CodingKeys: String, CodingKey {
        case id, cabinet, row, col, label, notes
        case partCount = "part_count"
        case firstPartNum = "first_part_num"
    }
}

struct DrawerWithParts: Codable {
    let drawer: Drawer
    let parts: [Part]
}

// MARK: - Identify

struct AIResult: Codable {
    let partNum: String?
    let name: String
    let category: String?
    let color: String?
    let description: String?
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case partNum = "part_num"
        case name, category, color, description, confidence
    }
}

struct LocationInfo: Codable {
    let drawerID: String
    let cabinet: Int?
    let row: String?
    let col: Int?
    let display: String

    enum CodingKeys: String, CodingKey {
        case drawerID = "drawer_id"
        case cabinet, row, col, display
    }
}

struct IdentifyResponse: Codable, Sendable {
    let ai: AIResult
    let existing: Part?
    let location: LocationInfo?
}

struct UploadResponse: Codable, Sendable {
    let uploadURL: String
    let s3Key: String

    enum CodingKeys: String, CodingKey {
        case uploadURL = "upload_url"
        case s3Key = "s3_key"
    }
}

// MARK: - Lookup

struct LookupResponse: Codable {
    let partNum: String
    let name: String?
    let foundOnBrickarchitect: Bool
    let brickarchitectURL: String
    let existing: Part?

    enum CodingKeys: String, CodingKey {
        case partNum = "part_num"
        case name
        case foundOnBrickarchitect = "found_on_brickarchitect"
        case brickarchitectURL = "brickarchitect_url"
        case existing
    }
}

// MARK: - Catalog

struct CatalogPart: Codable, Identifiable {
    let partNum: String
    let name: String
    let drawerID: String?
    let cabinet: Int?
    let row: String?
    let col: Int?

    var id: String { partNum }

    var locationDisplay: String? {
        guard let cabinet, let row, let col else { return nil }
        return "Cabinet \(cabinet)·\(row)\(col)"
    }

    var imageURL: URL? {
        URL(string: "https://brickarchitect.com/content/parts-large/\(partNum).png")
    }

    enum CodingKeys: String, CodingKey {
        case partNum = "part_num"
        case name
        case drawerID = "drawer_id"
        case cabinet, row, col
    }
}

struct CatalogStatus: Codable {
    let partsInCatalog: Int

    enum CodingKeys: String, CodingKey {
        case partsInCatalog = "parts_in_catalog"
    }
}

// MARK: - Models

struct AIModel: Codable, Identifiable {
    let id: String
    let label: String
}

struct ModelsResponse: Codable {
    let provider: String
    let active: String
    let available: [AIModel]
}
