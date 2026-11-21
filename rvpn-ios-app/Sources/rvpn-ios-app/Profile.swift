import Foundation

/// A connection profile — mirrors the Windows client's `Profile` model so
/// `.rvpn` files exported there import here unchanged.
struct Profile: Codable, Identifiable, Equatable {
    var id: String { slug }

    var slug: String
    var name: String
    /// Server WebSocket address, e.g. `wss://sg.example.com:443/api/v1/ws/tun`.
    var serverAddress: String
    /// TOFU server identity pin (`ik:1:<base32>); empty = trust on first use.
    var serverIdentity: String
    var dnsServers: [String]
    var blockAds: Bool
    var bypassDomains: [String]
    var tunnelDomains: [String]
    var builtinBypassCountries: [String]

    init(
        slug: String,
        name: String,
        serverAddress: String,
        serverIdentity: String = "",
        dnsServers: [String] = ["1.1.1.1", "8.8.8.8"],
        blockAds: Bool = false,
        bypassDomains: [String] = [],
        tunnelDomains: [String] = [],
        builtinBypassCountries: [String] = []
    ) {
        self.slug = slug
        self.name = name
        self.serverAddress = serverAddress
        self.serverIdentity = serverIdentity
        self.dnsServers = dnsServers
        self.blockAds = blockAds
        self.bypassDomains = bypassDomains
        self.tunnelDomains = tunnelDomains
        self.builtinBypassCountries = builtinBypassCountries
    }
}

/// `.rvpn` import document (same shape as the Windows client's ProfileExport).
struct ProfileExport: Codable {
    let format: String
    let version: Int
    let profile: ExportedProfile
    /// Raw prekey-bundle.json content.
    let prekeyBundle: String
    /// Base64 identity key file content; per-device keys are generated when absent.
    let identityKey: String?

    struct ExportedProfile: Codable {
        var slug: String?
        var name: String?
        var serverAddress: String?
        var dnsServers: [String]?
        var serverIdentity: String?
        var blockAds: Bool?
        var bypassDomains: [String]?
        var tunnelDomains: [String]?
        var builtinBypassCountries: [String]?
    }
}

/// Filesystem-backed profile store under `~/Documents/Profiles/<slug>/`.
enum ProfileStore {
    static var profilesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    static func profileDir(_ slug: String) -> URL {
        profilesRoot.appendingPathComponent(slug, isDirectory: true)
    }

    static func identityPath(_ slug: String) -> URL {
        profileDir(slug).appendingPathComponent("identity.key")
    }

    static func prekeyPath(_ slug: String) -> URL {
        profileDir(slug).appendingPathComponent("prekey-bundle.json")
    }

    static var indexFile: URL {
        profilesRoot.appendingPathComponent("profiles.json")
    }

    /// Load the profile list; returns [] when nothing is stored yet.
    static func load() -> [Profile] {
        guard let data = try? Data(contentsOf: indexFile),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data)
        else { return [] }
        return profiles
    }

    static func save(_ profiles: [Profile]) {
        try? FileManager.default.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }

    /// Ensure the profile directory exists with an identity key + prekey bundle.
    /// - Parameters:
    ///   - prekeyContent: raw prekey bundle JSON; written only when provided.
    ///   - identityBase64: identity file content; when nil a fresh per-device
    ///     identity is generated.
    static func provision(
        _ profile: Profile,
        prekeyContent: String?,
        identityBase64: String?
    ) -> Bool {
        let dir = profileDir(profile.slug)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let prekeyContent, !prekeyContent.isEmpty {
            try? prekeyContent.data(using: .utf8)?
                .write(to: prekeyPath(profile.slug), options: .atomic)
        }
        guard FileManager.default.fileExists(atPath: prekeyPath(profile.slug).path) else {
            return false
        }

        if let identityBase64,
           let raw = Data(base64Encoded: identityBase64),
           let text = String(data: raw, encoding: .utf8) {
            try? text.data(using: .utf8)?.write(to: identityPath(profile.slug), options: .atomic)
        }
        // Generate a per-device identity when none was imported.
        return RustBridge.generateIdentity(at: identityPath(profile.slug).path) == nil
    }

    static func delete(_ profile: Profile) {
        try? FileManager.default.removeItem(at: profileDir(profile.slug))
    }

    /// Human-readable import failure.
    struct ImportError: Error {
        let message: String
    }

    /// Import a `.rvpn` document; returns the stored profile.
    static func importDocument(_ doc: String, existing: [Profile]) -> Result<Profile, ImportError> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = doc.data(using: .utf8),
              let export = try? decoder.decode(ProfileExport.self, from: data)
        else { return .failure(ImportError(message: "Not a valid .rvpn profile file")) }
        guard export.format == "rvpn-profile" else {
            return .failure(ImportError(message: "Unrecognized profile format: \(export.format)"))
        }
        guard let address = export.profile.serverAddress, !address.isEmpty else {
            return .failure(ImportError(message: "Profile has no server address"))
        }

        var slug = (export.profile.slug ?? export.profile.name ?? "profile")
            .lowercased()
            .map { $0.isLetter && $0.isASCII || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "profile" }
        var taken = Set(existing.map(\.slug))
        if taken.contains(slug) {
            var n = 2
            while taken.contains("\(slug)-\(n)") { n += 1 }
            slug = "\(slug)-\(n)"
        }
        taken.insert(slug)

        let profile = Profile(
            slug: slug,
            name: export.profile.name ?? slug,
            serverAddress: address,
            serverIdentity: export.profile.serverIdentity ?? "",
            dnsServers: export.profile.dnsServers ?? ["1.1.1.1", "8.8.8.8"],
            blockAds: export.profile.blockAds ?? false,
            bypassDomains: export.profile.bypassDomains ?? [],
            tunnelDomains: export.profile.tunnelDomains ?? [],
            builtinBypassCountries: export.profile.builtinBypassCountries ?? []
        )
        guard provision(profile, prekeyContent: export.prekeyBundle, identityBase64: export.identityKey) else {
            return .failure(ImportError(message: "The prekey bundle inside the profile is invalid"))
        }
        return .success(profile)
    }

    /// MobileConfig JSON consumed by `rvpn_start` (camelCase on the Rust side).
    static func engineConfig(for profile: Profile) -> String {
        var config: [String: Any] = [
            "serverAddress": profile.serverAddress,
            "identityKeyPath": identityPath(profile.slug).path,
            "prekeyBundlePath": prekeyPath(profile.slug).path,
            "trustOnFirstUse": profile.serverIdentity.isEmpty,
            "dnsServers": profile.dnsServers,
            "blockAds": profile.blockAds,
            "bypassDomains": profile.bypassDomains,
            "tunnelDomains": profile.tunnelDomains,
            "builtinBypassCountries": profile.builtinBypassCountries,
        ]
        if !profile.serverIdentity.isEmpty {
            config["serverFingerprint"] = profile.serverIdentity
        }
        guard let data = try? JSONSerialization.data(withJSONObject: config) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
