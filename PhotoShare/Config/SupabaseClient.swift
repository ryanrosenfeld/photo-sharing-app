import Foundation
import Supabase

let supabase: SupabaseClient = {
    var url = Secrets.supabaseURL
    var key = Secrets.supabaseAnonKey
    #if DEBUG
    // Verification harness: point a simulator at local Supabase without touching Secrets.swift.
    let env = ProcessInfo.processInfo.environment
    if let envURL = env["PHOTOSHARE_SUPABASE_URL"], !envURL.isEmpty, URL(string: envURL) != nil,
       let envKey = env["PHOTOSHARE_SUPABASE_ANON_KEY"], !envKey.isEmpty {
        url = envURL
        key = envKey
    }
    #endif
    return SupabaseClient(supabaseURL: URL(string: url)!, supabaseKey: key)
}()
