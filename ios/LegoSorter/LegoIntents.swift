import AppIntents
import UIKit
import Security

// MARK: - Identify Intent

struct IdentifyLegoPartIntent: AppIntent {
    static var title: LocalizedStringResource = "Identify LEGO Part"
    static var description = IntentDescription(
        "Take or choose a photo of a LEGO part to identify it and find where it's stored in your collection.",
        categoryName: "LEGO Sorter"
    )
    static var openAppWhenRun = false

    @Parameter(title: "Photo of LEGO Part", supportedTypeIdentifiers: ["public.image"])
    var photo: IntentFile

    func perform() async throws -> some ProvidesDialog & ShowsSnippetView {
        guard let token = keychainGet("lego_access_token") else {
            return .result(
                dialog: "Please open LEGO Sorter and sign in first.",
                view: errorSnippet("Not signed in. Open the app to log in.")
            )
        }

        let rawData: Data
        do {
            rawData = try photo.data
        } catch {
            throw IntentError.noImage
        }

        guard let image = UIImage(data: rawData) else {
            throw IntentError.noImage
        }

        let imageData = compressImage(image)
        let result = try await identifyPart(imageData: imageData, token: token)
        let ai = result.ai

        // Build spoken response
        var dialog = "That's a \(ai.name)"
        if let partNum = ai.partNum { dialog += ", part number \(partNum)" }
        if let color = ai.color { dialog += ", in \(color)" }

        if let location = result.location {
            dialog += ". It's stored in \(location.display)."
        } else {
            dialog += ". It's not yet cataloged in your collection."
        }

        return .result(
            dialog: IntentDialog(stringLiteral: dialog),
            view: resultSnippet(ai: ai, location: result.location)
        )
    }

    // MARK: - Snippet views

    @MainActor
    private func resultSnippet(ai: AIResult, location: LocationInfo?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ai.name)
                        .font(.headline)
                    if let partNum = ai.partNum {
                        Text("#\(partNum)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let color = ai.color {
                        Text(color)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                let conf = Int(ai.confidence * 100)
                let confColor: Color = ai.confidence >= 0.8 ? .green : ai.confidence >= 0.5 ? .orange : .red
                Text("\(conf)%")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(confColor.opacity(0.15))
                    .foregroundColor(confColor)
                    .clipShape(Capsule())
            }

            if let partNum = ai.partNum,
               let url = URL(string: "https://brickarchitect.com/content/parts-large/\(partNum).png") {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFit()
                } placeholder: { EmptyView() }
                .frame(maxHeight: 100)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let location = location {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(location.display).font(.subheadline).fontWeight(.semibold)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Not yet cataloged").font(.subheadline)
                }
            }
        }
        .padding()
    }

    @MainActor
    private func errorSnippet(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            Text(message).font(.subheadline)
        }
        .padding()
    }

    // MARK: - API calls (self-contained, no dependency on app's service classes)

    private func identifyPart(imageData: Data, token: String) async throws -> IdentifyResponse {
        let base = "https://bootiak.org"

        // 1. Get presigned upload URL
        var uploadReq = URLRequest(url: URL(string: "\(base)/api/images/upload")!)
        uploadReq.httpMethod = "POST"
        uploadReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        uploadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        uploadReq.httpBody = try JSONSerialization.data(withJSONObject: ["content_type": "image/jpeg"])
        let (uploadData, _) = try await URLSession.shared.data(for: uploadReq)
        let upload = try JSONDecoder().decode(UploadResponse.self, from: uploadData)

        // 2. Upload to S3
        var s3Req = URLRequest(url: URL(string: upload.uploadURL)!)
        s3Req.httpMethod = "PUT"
        s3Req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        s3Req.httpBody = imageData
        _ = try await URLSession.shared.data(for: s3Req)

        // 3. Identify
        var identifyReq = URLRequest(url: URL(string: "\(base)/api/identify")!)
        identifyReq.httpMethod = "POST"
        identifyReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        identifyReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        identifyReq.httpBody = try JSONSerialization.data(withJSONObject: ["s3_key": upload.s3Key])
        let (identifyData, _) = try await URLSession.shared.data(for: identifyReq)
        return try JSONDecoder().decode(IdentifyResponse.self, from: identifyData)
    }

    private func compressImage(_ image: UIImage, maxBytes: Int = 4 * 1024 * 1024) -> Data {
        var quality: CGFloat = 0.85
        var data = image.jpegData(compressionQuality: quality) ?? Data()
        while data.count > maxBytes && quality > 0.3 {
            quality -= 0.15
            data = image.jpegData(compressionQuality: quality) ?? Data()
        }
        return data
    }

    private func keychainGet(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum IntentError: LocalizedError {
        case noImage
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .noImage: return "Could not read the photo. Please try again."
            case .notSignedIn: return "Please open LEGO Sorter and sign in first."
            }
        }
    }
}
