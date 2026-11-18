import AppKit
import Foundation

/// Checks GitHub Releases for a newer version and can replace the running app with it.
enum Updater {
    static let repo = "wangmengjames/ReTerm"
    static let assetName = "ReTerm.zip"
    static let lastCheckKey = "lastUpdateCheck"

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var zipURL: URL? { assets.first { $0.name == Updater.assetName }.flatMap { URL(string: $0.browser_download_url) } }
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case noAsset
        case badArchive(String)
        case notInstalledAsApp

        var errorDescription: String? {
            switch self {
            case .http(let code): return "GitHub answered with status \(code)."
            case .noAsset: return "The release has no \(Updater.assetName) download."
            case .badArchive(let why): return "The downloaded update was rejected: \(why)."
            case .notInstalledAsApp: return "ReTerm is not running from a writable .app bundle."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Numeric comparison of dotted versions: "0.10.0" is newer than "0.9.1".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func fetchLatest(completion: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ReTerm", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UpdateError.http(http.statusCode))
            } else {
                result = Result { try JSONDecoder().decode(Release.self, from: data ?? Data()) }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Downloads the release, checks it really is this app at that version, and swaps it in.
    /// Calls back on the main queue with the bundle location to relaunch.
    static func install(_ release: Release, completion: @escaping (Result<URL, Error>) -> Void) {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            completion(.failure(UpdateError.notInstalledAsApp))
            return
        }
        guard let zip = release.zipURL else {
            completion(.failure(UpdateError.noAsset))
            return
        }
        URLSession.shared.downloadTask(with: zip) { file, response, error in
            let result: Result<URL, Error> = Result {
                if let error { throw error }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.http(http.statusCode) }
                guard let file else { throw UpdateError.noAsset }
                let fm = FileManager.default
                // Same volume as the app, so the final swap is a rename.
                let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
                defer { try? fm.removeItem(at: work) }
                let unpack = Process()
                unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unpack.arguments = ["-x", "-k", file.path, work.path]
                try unpack.run()
                unpack.waitUntilExit()
                guard unpack.terminationStatus == 0 else { throw UpdateError.badArchive("could not unpack") }

                let fresh = work.appendingPathComponent("ReTerm.app")
                guard let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist")),
                      info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                    throw UpdateError.badArchive("not a ReTerm app")
                }
                guard info["CFBundleShortVersionString"] as? String == release.version else {
                    throw UpdateError.badArchive("version does not match the release")
                }
                let verify = Process()
                verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                verify.arguments = ["--verify", "--deep", "--strict", fresh.path]
                verify.standardError = FileHandle.nullDevice
                try verify.run()
                verify.waitUntilExit()
                guard verify.terminationStatus == 0 else { throw UpdateError.badArchive("code signature is broken") }

                _ = try fm.replaceItemAt(bundle, withItemAt: fresh)
                return bundle
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func relaunch(_ bundle: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundle.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
