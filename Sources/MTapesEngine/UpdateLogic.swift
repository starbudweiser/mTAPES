// mTAPES — logique pure de la mise à jour (testée) : comparaison de versions et choix de l'asset d'une release GitHub.
import Foundation

public struct ReleaseAsset: Equatable {
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public enum UpdateLogic {
    /// « v1.0.1 » > « 1.0.0 » ; les composantes manquantes valent 0 ; un suffixe non numérique (« 1.0.1-beta ») est ignoré.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Format publié par release.sh : `mTAPES-<version>-macOS-arm64.zip` + `<même nom>.sha256`. Le zip d'une autre architecture est écarté.
    public static func pickAsset(_ assets: [ReleaseAsset], arch: String = "arm64") -> (zip: ReleaseAsset, sha256: ReleaseAsset?)? {
        let zips = assets.filter { $0.name.hasPrefix("mTAPES-") && $0.name.hasSuffix(".zip") }
        let other = ["x86_64", "intel", "universal"].filter { $0 != arch }
        let usable = zips.filter { z in !other.contains { z.name.lowercased().contains($0) } }
        guard let zip = usable.first(where: { $0.name.contains(arch) }) ?? usable.first else { return nil }
        return (zip, assets.first { $0.name == zip.name + ".sha256" })
    }

    /// Première ligne d'un fichier `.sha256` (« <hash>  <nom> ») : le hash en minuscules, ou nil s'il n'a pas 64 chiffres hexadécimaux.
    public static func parseSHA256(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased(),
              first.count == 64, first.allSatisfy({ $0.isHexDigit }) else { return nil }
        return first
    }
}

/// Nombre d'exports (rendus) en cours dans ce processus : la mise à jour automatique attend qu'il soit nul.
public enum ActiveExports {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var n = 0
    public static var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    static func begin() { lock.lock(); n += 1; lock.unlock() }
    static func end() { lock.lock(); n -= 1; lock.unlock() }
}
