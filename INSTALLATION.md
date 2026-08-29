# Installation

Two halves: getting the app onto an iPhone, and standing up the backend it
talks to. The app runs without the backend — the library, the recipe editor and
every Bluetooth feature are local — so you can do the first half, brew with it,
and come back for the second when you want sync and AI.

- [1. Get the app onto your iPhone](#1-get-the-app-onto-your-iphone)
- [2. Set up your own Supabase project](#2-set-up-your-own-supabase-project)
- [3. Point the app at your project](#3-point-the-app-at-your-project)
- [4. First run](#4-first-run)
- [Troubleshooting](#troubleshooting)

---

## 1. Get the app onto your iPhone

### What you need

| | |
|---|---|
| A Mac | with the **full Xcode** app, not just the Command Line Tools |
| An iPhone | iOS 17 or later |
| An Apple ID | a free one is enough for a 7-day build; a paid Developer account lasts a year |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `brew install xcodegen` — the `.xcodeproj` is generated from `project.yml` |

There is no App Store build and no TestFlight. You build it and install it
yourself, which is also why nothing in it phones home to anybody but you.

### Steps

```sh
git clone https://github.com/Lui35/Enahnced-Xbloom-IOS-App.git
cd Enahnced-Xbloom-IOS-App
cp Secrets.example.xcconfig Secrets.xcconfig   # your backend goes here later
xcodegen generate
open XBloom.xcodeproj
```

`Secrets.xcconfig` is not in the repository and never should be — it is where
your own Supabase project goes in [step 3](#3-point-the-app-at-your-project).
Left blank, everything except sync and AI still works.

1. **Open Xcode once first** if you never have — accept the licence and let it
   install its components.
2. In Xcode, select the **XBloom** target → **Signing & Capabilities**.
3. Set **Team** to your Apple ID. Xcode will complain that the bundle
   identifier is taken; change **Bundle Identifier** to something of your own,
   e.g. `com.yourname.xbloom`. Do the same for the **XBloomLiveActivity**
   target, keeping it as `<your bundle id>.LiveActivity`.
4. Plug in your iPhone and trust the Mac.
5. Pick your iPhone as the run destination and press **Run** (⌘R).
6. On the iPhone: **Settings → General → VPN & Device Management** → trust your
   developer certificate. The app will not launch until you do.

With a free Apple ID the build stops working after seven days; rebuild from
Xcode to renew it.

### Running it without a machine

The simulator can run everything except Bluetooth. Useful launch arguments, set
in **Product → Scheme → Edit Scheme → Arguments**:

| Argument | What it does |
|---|---|
| `-seedBeanRelationshipPreview` | Adds a demo bean with a linked recipe |
| `-seedHistoryPreview` | Adds demo brew history with telemetry |
| `-seedPendingRecipe` | Shows the "designing a recipe" card without calling the AI |

Each guards against re-seeding, so an existing container keeps what it has.

---

## 2. Set up your own Supabase project

**Do not use the project in the source.** The URL and publishable key currently
committed point at the author's project; a fork left as-is would sign your
users into somebody else's database. Make your own — the free tier is more than
enough for one person's coffee.

### 2a. Create the project

1. Sign up at [supabase.com](https://supabase.com) and create a project.
2. Note the **Project URL** and the **publishable (anon) key** from
   **Project Settings → API**. The publishable key is safe to ship in a client;
   it is the service-role key that must never leave a server, and this app never
   uses one.

### 2b. Create the schema

The schema is two migrations in `supabase/migrations/`. Either run them from
the Supabase SQL editor in filename order, or use the CLI:

```sh
brew install supabase/tap/supabase
supabase link --project-ref <your-project-ref>
supabase db push
```

That gives you:

| Table | Holds |
|---|---|
| `profiles` | one row per user, sync bookkeeping |
| `beans` | bags, with the full profile as JSON |
| `recipes` | programs, linked to a bean |
| `brews` | history, with telemetry samples as JSON |
| `inventory_events` | bag weight changes |
| `maintenance_events` | one row per service performed on the machine |
| `user_settings`, `ai_request_usage` | preferences and AI request accounting |

Every table has Row Level Security on and a single policy: `auth.uid() =
user_id`. `anon` is granted nothing. Your rows are unreadable to anyone but you,
including anyone else who signs up in the same project.

### 2c. Deploy the AI function

All AI calls go through one Edge Function so your Gemini key stays on the
server:

```sh
supabase functions deploy coffee-ai
supabase secrets set GEMINI_API_KEY=<your key from aistudio.google.com>
```

The function verifies the caller's JWT, rate-limits to 20 requests a minute per
user, caps request bodies at 20 MB, and only accepts model names matching
`gemini-*`. It records every call in `ai_request_usage` — action, model, status,
error code — which is the first place to look when the AI misbehaves.

### 2d. Bean label photos (optional)

Bag photos are uploaded to a private `bean-labels` storage bucket, created by
the first migration with per-user folder policies. Nothing to do unless you
deleted it.

---

## 3. Point the app at your project

Put your values in `Secrets.xcconfig` — the file you copied in step 1, which is
gitignored:

```
SUPABASE_HOST = your-project-ref.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_...
```

The host has no `https://` because `//` starts a comment in an xcconfig file;
the scheme is added back in code. Then regenerate and rebuild:

```sh
xcodegen generate
```

They reach the app as `Info.plist` values, so nothing about your project is ever
committed. A build with them blank runs local-only and says so on the Account &
AI screen — which is exactly what the IPAs in [Releases](../../releases) are,
since a public build must not carry anybody's backend.

> **Keep it that way.** The publishable key is meant to be readable by a client
> and Row Level Security keeps your rows private, but anyone holding it can
> create an account in your project and spend your AI quota through the Edge
> Function. If a key of yours has ever been public, rotate it in
> **Project Settings → API Keys**, and consider turning off new sign-ups in
> **Authentication → Sign In / Providers**.

There is also a URL scheme for the sign-in callback, `xbloom://login-callback`,
declared in `project.yml`. If you changed the bundle identifier you can leave
the scheme alone; it only has to match what you register in **Supabase →
Authentication → URL Configuration → Redirect URLs**.

---

## 4. First run

1. Launch the app. It works immediately — beans, recipes, the editor, the
   preview mode, and Bluetooth all run with no account.
2. **Settings → Account & AI → Create an account** with an email and a
   password of 8+ characters. If you left email confirmations on in Supabase,
   confirm the email before signing in.
3. Back on that screen, **Test the connection**. A green result means the Edge
   Function, your key and your model name all work.
4. **Sync now** pushes your local library up.

### Connecting the machine

Wake the xBloom, close the official app — it holds the Bluetooth connection —
and tap **Connect** on the Home tab. The app scans for a peripheral advertising
`XBLOOM` or the xBloom service UUID, remembers it, and reconnects directly next
time.

If a brew misbehaves, **Settings → Machine diagnostics** records the raw
Bluetooth session and lets you share the transcript. Every protocol finding in
`docs/` came out of one of those recordings.

---

## Troubleshooting

**"No xBloom was found."**
The official app is almost certainly still connected. Close it fully, make sure
the machine is awake, and try again.

**Xcode: "Failed to register bundle identifier".**
Someone else owns `coffee.xbloom.native`. Change it to your own, and change the
Live Activity target to match.

**Xcode can't find a new file I added.**
`XBloom.xcodeproj` is generated from `project.yml` and lists app sources
explicitly. Run `xcodegen generate` after adding anything under `XBloomApp/`.
Files under `Sources/XBloomCore/` are picked up automatically.

**AI requests fail.**
Query your own log first:

```sql
select created_at, action, model, status, error_code
from public.ai_request_usage
order by created_at desc limit 20;
```

`gemini_http_503` means Google is overloaded — try a different model in
Settings → Account & AI. A `timeout` is usually the same thing. A 401 means the
function's `GEMINI_API_KEY` secret is missing or wrong.

**Sync fails on `maintenance_events`.**
That table came in the second migration. Run it.

**The app builds but Bluetooth does nothing in the simulator.**
It cannot. The simulator has no Bluetooth stack; use a real iPhone.
