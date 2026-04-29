# TODO — Pre-Launch Checklist

Tasks deferred during development that must be completed before shipping.

---

## Auth

- [ ] **Re-enable email confirmation in Supabase**
  Email confirmation is currently disabled in the Supabase dashboard (Authentication → Providers → Email → "Confirm email") for development convenience. Must be re-enabled before launch to prevent account takeover via unverified email addresses.

---

## Onboarding

- [ ] Switch auth from email/password to phone number (SMS)
  Per the spec, the intended sign-up flow is phone number + SMS verification. Email/password was used early on to avoid SMS costs and friction; swap before launch.

