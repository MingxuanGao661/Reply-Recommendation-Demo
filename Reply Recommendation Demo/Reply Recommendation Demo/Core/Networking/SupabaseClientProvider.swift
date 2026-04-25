import Foundation
import Supabase

final class SupabaseClientProvider {
    static let shared = SupabaseClientProvider()

    let client: SupabaseClient
    let baseURL: URL
    let anonKey: String

    var isConfigured: Bool {
        !anonKey.isEmpty && !anonKey.contains("REPLACE_WITH")
    }

    private static let supabaseURLString = "https://spbfeyrvbzazmlselvfb.supabase.co"
    private static let bundledAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNwYmZleXJ2Ynphem1sc2VsdmZiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcwNzgzODUsImV4cCI6MjA5MjY1NDM4NX0.VcDoRfHC1DD7jw1ZuMHiFifSEpntTWhQYfzbvykmwdc"

    private init() {
        guard let url = URL(string: Self.supabaseURLString) else {
            fatalError("Invalid Supabase URL.")
        }

        let configuredKey = ProcessInfo.processInfo.environment["SOCIALDRAFT_SUPABASE_ANON_KEY"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SOCIALDRAFT_SUPABASE_ANON_KEY") as? String
            ?? Self.bundledAnonKey

        baseURL = url
        anonKey = configuredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions()
        )
    }
}
