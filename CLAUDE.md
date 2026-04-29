# CLAUDE.md — Instructions for Claude Sessions

## On every session start

1. **Read [`SPEC.md`](SPEC.md)** — the product specification. Understand what the app is supposed to do before writing any code.
2. **Read [`ARCHITECTURE.md`](ARCHITECTURE.md)** — the system architecture, tech stack, project structure, and decision log. Understand *why* things are built the way they are.

---

## When to update docs

### Update `SPEC.md` when:
- Product behavior changes (new features, removed features, rule changes)
- Edge cases are clarified or added
- The freemium model or any user-facing behavior is modified

### Update `ARCHITECTURE.md` when:
- A new library or service is added or removed
- The folder/file structure changes meaningfully
- A significant architectural decision is made (add an entry to the Decision Log with date and reasoning)
- The data model or push notification flow changes
- A new major component or pattern is introduced

---

## Project conventions

- **`project.yml` is the source of truth** for the Xcode project. After changing it, run `xcodegen generate`. Never hand-edit `.xcodeproj`.
- **`Secrets.swift` is gitignored.** Never commit it. Use `Secrets.template.swift` at the project root as the reference for what values are needed.
- **Swift 6 strict concurrency is enabled.** All new code must be concurrency-safe. Prefer `@MainActor` on ViewModels. Avoid `nonisolated(unsafe)` unless truly necessary.
- **Deployment target is iOS 17.** Don't use APIs introduced after iOS 17 without an availability check.
- **Face embeddings never leave the device.** This is a hard privacy constraint. Do not write code that uploads embeddings or raw face data to any server.

---

## Key files

| File | Purpose |
|---|---|
| `SPEC.md` | Product spec — read first |
| `ARCHITECTURE.md` | Architecture + decision log — read second |
| `project.yml` | XcodeGen config — source of truth for project structure |
| `Secrets.template.swift` | Template for API keys (actual `Secrets.swift` is gitignored) |
| `PhotoShare/Config/SupabaseClient.swift` | Global `supabase` singleton |
| `PhotoShare/Auth/AuthManager.swift` | Auth state + sign-in methods |
| `PhotoShare/ContentView.swift` | Root router |
