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
- The data model or push notification flow changes
- A new major component or pattern is introduced

### Update `DECISIONS.md` when:
- A significant architectural or product decision is made — add an entry with date, alternatives considered, reasoning, and trade-offs accepted
- `DECISIONS.md` is intentionally kept out of the default session context (it's verbose). Read it only when investigating why something was built a certain way.

---

## Project conventions

- **`project.yml` is the source of truth** for the Xcode project. After changing it, run `xcodegen generate`. Never hand-edit `.xcodeproj`.
- **`Secrets.swift` is gitignored.** Never commit it. Use `Secrets.template.swift` at the project root as the reference for what values are needed.
- **Swift 6 strict concurrency is enabled.** All new code must be concurrency-safe. Prefer `@MainActor` on ViewModels. Avoid `nonisolated(unsafe)` unless truly necessary.
- **Deployment target is iOS 17.** Don't use APIs introduced after iOS 17 without an availability check.
- **Verify changes with `make verify`** (and `make scenario` for end-to-end flows); see `scripts/verify/README.md`.
- **Face embeddings never leave the device.** This is a hard privacy constraint. Do not write code that uploads embeddings or raw face data to any server.

---

## Accessibility (required for every UI change)

Follow Apple's accessibility guidance on every screen, and run `make verify`, which includes `PhotoShareUITests/AccessibilityAuditTests` (Apple's `performAccessibilityAudit()`). Fix findings; do not ignore audit issue types to make it pass. When you add a screen, add it to that test.

- **Contrast:** text and meaningful icons need at least 4.5:1 against their background (3:1 for large text 18pt+ or bold 14pt+, and for UI component borders). Check `OttoTheme` pairings, including text on photos, on tinted surfaces, and on Liquid Glass. Never convey state by color alone.
- **Dynamic Type:** use text styles or `OttoTheme` fonts that scale (`relativeTo:`); no fixed-size text frames. Layouts must hold at the largest accessibility sizes (wrap, scroll, or switch with `ViewThatFits`; never truncate essential text).
- **VoiceOver:** every control and meaningful image has a concise label (`accessibilityLabel`), value, and hint where needed; decorative images are hidden; group related elements (`accessibilityElement(children: .combine)`); keep a logical reading order; announce async state changes. Keep `accessibilityIdentifier`s for tests separate from labels.
- **Hit targets:** at least 44x44pt for everything tappable (`contentShape` / `frame(minWidth:minHeight:)` if the visual is smaller).
- **Reduce Motion / Transparency / Increase Contrast:** read `accessibilityReduceMotion`, `accessibilityReduceTransparency`, and `colorSchemeContrast`. With Reduce Motion, replace movement with a fade or nothing. With Reduce Transparency or Increase Contrast, Liquid Glass and translucent materials must fall back to opaque surfaces with solid text. Do not put text over glass without verifying contrast in light and dark.
- **Other:** support Dark Mode, Bold Text, Button Shapes, and Voice Control (labels match visible text). Copy stays lowercase.
- Adopt Liquid Glass only for controls and navigation, gated with `#available(iOS 26, *)` and a fallback.

---

## Key files

| File | Purpose |
|---|---|
| `SPEC.md` | Product spec — read first |
| `ARCHITECTURE.md` | Architecture, tech stack, data model — read second |
| `DECISIONS.md` | Decision log — read only when investigating why something was built a certain way |
| `project.yml` | XcodeGen config — source of truth for project structure |
| `Secrets.template.swift` | Template for API keys (actual `Secrets.swift` is gitignored) |
| `PhotoShare/Config/SupabaseClient.swift` | Global `supabase` singleton |
| `PhotoShare/Auth/AuthManager.swift` | Auth state + sign-in methods |
| `PhotoShare/ContentView.swift` | Root router |

