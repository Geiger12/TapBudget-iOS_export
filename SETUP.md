# TapBudget for iPhone: from this folder to TestFlight

This folder is a complete Xcode project. You do not need to build it on your own Mac: Xcode Cloud builds it in
Apple's cloud, and TestFlight puts it on your iPhone. Your Mac is only needed once, to create the workflow.

What is in it
- `TapBudget.xcodeproj` with a shared `TapBudget` scheme (Xcode Cloud only sees shared schemes)
- `TapBudget/App.swift` and `TapBudget/ContentView.swift`: the app
- `TapBudget/Assets.xcassets`: the app icon (your artwork, cropped to exactly 1024 x 1024, no transparency) and accent color
- `TapBudget/PrivacyInfo.xcprivacy`: says the app tracks nothing and collects nothing
- `Config/Info.plist`: tells App Store Connect the app uses no non-exempt encryption, so uploads do not stop to ask
- Settings: bundle ID `com.tapbudget.app`, version 2.0, iPhone only, minimum iOS 26.0, automatic signing

You need a paid Apple Developer Program membership. If you are not sure whether yours is an individual or an
organization account, that is fine: both work.

## 1. Put the folder on GitHub (a new repository, separate from the web app)

Create a repository named `TapBudget-iOS` on github.com. Easiest way, with GitHub Desktop:
File > Add Local Repository > choose this folder > "create a repository" > Publish repository.

Without GitHub Desktop: on github.com open the new repository > "uploading an existing file" and drag in
everything inside this folder (`TapBudget.xcodeproj`, `TapBudget`, `Config`, `SETUP.md`), then Commit.

Leave the old web-app repository and its old Xcode Cloud workflow alone. This is a separate product.

## 2. Open it in Xcode and choose your team (once)

1. Double-click `TapBudget.xcodeproj`.
2. Click the blue TapBudget project in the left list, then the TapBudget target, then Signing & Capabilities.
3. Tick "Automatically manage signing" and pick your Team.
4. Commit and push that change (Xcode: Source Control > Commit, then Push).

If your Mac's Xcode is older than version 26, it cannot build this locally (it needs the iOS 26 SDK). That is
fine. Just set the team and push. Xcode Cloud builds with a newer Xcode.

If Xcode will not open the project at all, use this fallback: File > New > Project > iOS > App (SwiftUI, name
TapBudget, bundle ID com.tapbudget.app), delete its generated ContentView and App files, drag in
`App.swift`, `ContentView.swift`, `Assets.xcassets` and `PrivacyInfo.xcprivacy` from this folder, set the
minimum deployment to iOS 26.0, and carry on from step 3.

## 3. Create the Xcode Cloud workflow

1. In Xcode: Integrate menu > Xcode Cloud > Create Workflow...
2. Pick the TapBudget product and connect GitHub when asked. Give Xcode Cloud access to the `TapBudget-iOS` repository.
3. Accept the default workflow. It builds whenever you push to the main branch.
4. Open the workflow (Integrate > Manage Workflows) and check:
   - Environment: Xcode version "Latest Release" (the newest Xcode Apple offers)
   - Start Conditions: Branch Changes, main
   - Actions: Archive - iOS, scheme TapBudget

## 4. Set up distribution (this creates the App Store Connect app and the TestFlight workflow)

In Xcode's Cloud navigator, right-click (secondary click) the TapBudget app and choose "Set Up Distribution...".
Enter the app name, the bundle ID (`com.tapbudget.app`) and a SKU (any short unique text, for example
`tapbudget-ios`). Xcode Cloud creates the App Store Connect app record, registers the bundle ID, and makes a
workflow that sends builds to internal TestFlight testers.

If the bundle ID is already taken by an app you created earlier, choose it from your existing apps. If it
belongs to someone else, use a different one (for example `com.yourname.tapbudget`) in BOTH the target's
Signing & Capabilities and here.

## 5. Build, then install from TestFlight

1. Start a build: Xcode > Integrate > Xcode Cloud > Start Build (or just push a commit). Watch it in the Report
   navigator (Cloud tab) or at appstoreconnect.apple.com > your app > Xcode Cloud.
2. When the build finishes, open App Store Connect > Apps > TapBudget > TestFlight. Wait for the build to
   finish processing.
3. Internal Testing > "+" > create a group (for example "Me") > add yourself. Your Apple Account must be a user
   under Users and Access. Turn on automatic distribution so every new build goes out.
4. On your iPhone, install the TestFlight app from the App Store, open the invitation, and install TapBudget.
   The iPhone must run iOS 26 or newer.

Internal testers get a build as soon as it finishes processing. Only external testers need Beta App Review.

## If something goes wrong

- Build fails with a Swift error: open the build log (Report navigator > the failed build > the Build step) and
  send me the red lines. The screens were written without being able to run Xcode, so a few fixes are likely.
- "No account for team" or a signing error: step 2, pick the team and push again.
- "Bundle identifier is not available": see step 4.
- "Build number already used": Apple's page "Setting the next build number for Xcode Cloud builds" shows how to
  raise it, or raise `MARKETING_VERSION` (currently 2.0) in the target and push.
- To start with your real budget: in the app, Settings > Back up > Import a backup, and paste in a backup file
  saved from the web app.

Needed later for the App Store (not for TestFlight): privacy policy URL
https://tapbudget-ashy.vercel.app/about/privacy.html, the App Privacy answers (the privacy manifest in this
project says no data is collected), and screenshots.
