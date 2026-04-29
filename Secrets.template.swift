// Secrets.template.swift
// Copy this file to Secrets.swift and fill in your values.
// Secrets.swift is gitignored and must never be committed.
//
// Setup steps:
// 1. Create a Supabase project at https://supabase.com
//    → Settings > API → copy "Project URL" and "anon public" key
// 2. Enable Apple provider: Supabase Dashboard → Auth → Providers → Apple
//    → Requires Apple Developer account + Services ID + private key
// 3. Enable Google provider: Supabase Dashboard → Auth → Providers → Google
//    → Requires Google Cloud Console OAuth client
//    → Download GoogleService-Info.plist and add to the Xcode project
//    → Set GOOGLE_REVERSED_CLIENT_ID build setting to the value from that plist

enum Secrets {
    static let supabaseURL = ""
    static let supabaseAnonKey = ""
    static let googleClientID = "" // GOOGLE_CLIENT_ID from GoogleService-Info.plist
}
