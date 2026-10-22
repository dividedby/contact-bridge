import Foundation
import Testing

/// Loads JSON from the test bundle's Fixtures resources.
enum GoogleFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}
