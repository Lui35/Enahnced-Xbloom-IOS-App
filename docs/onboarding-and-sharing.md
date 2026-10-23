# Onboarding, accounts, and recipe links

First launch shows a five-step introduction: capabilities and supported machine,
Bluetooth setup, the first brew, everyday tools, and account choices. Skipping
the tour goes to the account choices. Guests can enter the app immediately.
Completion is stored on the device; the guide remains available in Settings.
Bluetooth initializes when the user taps Connect or finishes onboarding, so the
permission prompt follows the connection guidance. Later launches automatically
attempt the saved-machine connection.

## Account choices

- **Guest:** local beans, recipes, favorites, history, Bluetooth brewing and
  tools, maintenance, file transfers, and recipe links.
- **Signed in:** adds cloud sync/restore and authenticated AI bag import,
  recipe generation, and recipe improvement. Internet access is required.

Email sign-up and login use the existing Supabase backend. A new, empty account
that has never completed a sync adopts the on-device recipes. An established
account restores its cloud recipe list, including an intentionally empty list;
the account screen explains this and recommends exporting before switching.

The native Apple button exchanges Apple's identity token with Supabase using
a fresh nonce (SHA-256 sent to Apple, original nonce sent to Supabase). Canceling
Apple authorization leaves the guest choice available. No private Apple key or
service-role key belongs in the app.

### Enable Sign in with Apple for a distributed build

1. In Apple Developer, enable **Sign in with Apple** for the app's bundle ID
   (`coffee.xbloom.native`, or your replacement). Refresh the provisioning profile.
   The entitlement is already included in `project.yml` and
   `XBloomApp/Resources/XBloom.entitlements`.
2. In Supabase **Authentication → Providers → Apple**, enable the provider and
   add that exact bundle ID to its allowed Client IDs. Native-only identity-token
   sign-in does not require a web Services ID/client-secret rotation. If also
   supporting web OAuth, follow its separate Apple configuration requirements.
3. Keep `xbloom://login-callback` on Supabase's redirect allowlist for email
   confirmations. Configure email confirmation and delivery for the environment.
4. Verify a first Apple sign-in, returning sign-in, Hide My Email, cancellation,
   email confirmation, and sign-out on a properly signed iPhone build.

See [Supabase's Apple guide](https://supabase.com/docs/guides/auth/social-login/auth-apple)
and [Apple's native sign-in guide](https://developer.apple.com/documentation/authenticationservices/implementing-user-authentication-with-sign-in-with-apple).
The simulator build and local tests do not prove Apple/provider configuration.

### Configured backend status — 21 October 2026

The app's configured Supabase project now has native Apple sign-in enabled for
`coffee.xbloom.native`, email authentication enabled, and new registrations
enabled with email confirmation required. The site URL and redirect allowlist
already contain `xbloom://login-callback`. These settings were verified in the
dashboard after saving and through the public Auth settings endpoint.

The existing profile and recipe schema already supports this flow; no database
migration was needed. The core user-data tables were checked for owner-scoped
row-level security. Apple Developer capability/provisioning and an end-to-end
sign-in test on a signed iPhone build remain separate from this Supabase setup.

## Share and receive one recipe

Open a recipe, tap its **…** menu, then **Share recipe link**. Share or copy the
link. A link contains a versioned snapshot of the recipe, with no access to the
sender's account. It excludes bean relationships, source-brew and parent IDs,
and favorite status. Changes to the original do not update an existing link.
The recipe's displayed description and brewing settings are included.

Links use `xbloom://recipe?data=…` and require xBloom to be installed. They work
offline without an account or a sharing server. Some messaging apps do not make
custom-scheme links tappable; the recipient can paste one into **Settings →
Import recipe link** instead. These are app links, with no browser preview or
universal-link domain setup.

Opening a link shows a preview. **Save to my recipes** validates its brewing
settings and inserts a new recipe with fresh IDs. Opening a link never starts
the machine or overwrites an existing recipe. A link received during first-run
onboarding waits until onboarding is complete before showing the preview.
Malformed, unsupported-version, unsafe, and oversized links are rejected. Links
are capped at 16 KB; the existing file-transfer flow is available for larger
descriptions or library exports.

## Verification

`swift test` includes portable-link round trips, Unicode names, privacy stripping,
new-copy IDs, bad inputs, future versions, unsafe settings, and integer-overflow
inputs. App tests cover durable imports, preserving originals, unsafe import
rejection, and adoption of guest recipes. UI tests cover tour navigation,
skipping to account choices, guest access, and completion across app relaunches.
They also open a real recipe URL during onboarding, save it after the guest
choice, check that it appears in Recipes, and reject a malformed URL.

Account-form UI tests need a configured form, but never submit credentials.
CI uses `SUPABASE_HOST=ui-tests.invalid` and
`SUPABASE_PUBLISHABLE_KEY=ui-test-placeholder`; pass the same build settings to
`xcodebuild test` locally to run without a real backend. CI keeps the full build
log and `.xcresult` bundle in its `app-test-results` artifact.

For a fresh onboarding preview in a Debug build, use `-resetOnboarding` as a
launch argument. Remove it to check normal returning-user behavior.

## Interface design

The onboarding and account screens follow the UI/UX Pro Max guidance for native
SwiftUI forms, skippable tours, touch targets, and accessibility. Four visual
chapters lead into the optional account screen. The existing charcoal and warm
amber palette is retained, with native serif headings and local vector artwork.
Back and Skip remain available; Back from a skipped tour returns to the chapter
the user left. Only the progress indicator animates between chapters, avoiding
overlapping screens. Reduced Motion disables the small state transitions.

The account screen separates Apple sign-in, email login/account creation, and
guest access. Fields have persistent labels, focus outlines, Next/Go keyboard
actions, inline validation, password visibility controls, and password-manager
support. The account comparison expands on demand. Login still explains the
cloud-library replacement behavior, and creation explains email confirmation.

Content scrolls between fixed safe-area headers and footers. Decorative artwork
is hidden from VoiceOver; body and form text follow Dynamic Type. Navigation
branding and chapter kickers have bounded scaling so they do not crowd out the
controls. Screens use the app's established dark appearance. The shipping target
is portrait iPhone; tablet and landscape layouts are outside its supported scope.
