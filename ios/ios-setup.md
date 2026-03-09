# iOS App Setup Guide

## Prerequisites
- Xcode 15 or later
- Apple Developer account (for running on a physical device)
- The `ios-app` branch checked out

---

## Step 1 — Create the Xcode Project

1. Open Xcode
2. **File > New > Project**
3. Select **iOS > App** and click Next
4. Fill in the fields:
   - **Product Name:** `LegoSorter`
   - **Team:** select your Apple Developer account
   - **Organization Identifier:** anything (e.g. `com.yourname`)
   - **Interface:** SwiftUI
   - **Language:** Swift
   - Uncheck "Include Tests"
5. Save the project inside `lego-sorting/ios/` (next to the `LegoSorter/` folder)

---

## Step 2 — Replace the Generated Files

Xcode generates placeholder files. Replace them with the source files from this repo.

1. In the Xcode project navigator (left panel), **delete** the two auto-generated files:
   - `ContentView.swift`
   - `LegoSorterApp.swift`
   - Choose **"Move to Trash"** when prompted

2. Right-click the **LegoSorter** folder in the project navigator and choose **"Add Files to 'LegoSorter'…"**

3. Navigate to `lego-sorting/ios/LegoSorter/` and select **all `.swift` files**:
   - `LegoSorterApp.swift`
   - `Models.swift`
   - `AuthService.swift`
   - `APIService.swift`
   - `ContentView.swift`
   - `LoginView.swift`
   - `IdentifyView.swift`
   - `DrawerPickerSheet.swift`
   - `EditPartSheet.swift`
   - `BrowseView.swift`
   - `DrawersView.swift`
   - `DataView.swift`
   - `LegoIntents.swift`
   - `AppShortcuts.swift`

4. Make sure **"Copy items if needed"** is unchecked (the files are already in the right place) and **"Add to target: LegoSorter"** is checked. Click Add.

---

## Step 3 — Add Privacy Descriptions (Info.plist)

The app needs camera and photo library access. Add these keys to your `Info.plist`:

1. In the project navigator, click your project (the top item with the blue icon)
2. Select the **LegoSorter** target > **Info** tab
3. Hover over any row and click the **+** button to add each key:

| Key | Value |
|-----|-------|
| `Privacy - Camera Usage Description` | `Take photos of LEGO parts to identify them` |
| `Privacy - Photo Library Usage Description` | `Choose photos of LEGO parts to identify them` |
| `Privacy - Siri Usage Description` | `Used to identify LEGO parts from photos` |

---

## Step 4 — Add Capabilities

### Siri
1. Click your project (blue icon) > select the **LegoSorter** target > **Signing & Capabilities** tab
2. Click **+ Capability**
3. Search for **Siri** and double-click to add it

### Background (optional — for intent reliability)
If you want the identify intent to work reliably when the app is in the background, also add:
- **Background Modes** → check **Background processing**

---

## Step 5 — Select a Device and Run

1. At the top of Xcode, click the device selector (next to the play button)
2. If running on a **physical iPhone** (recommended):
   - Plug in your iPhone via USB
   - Select your iPhone from the list
   - First run: go to **Settings > General > VPN & Device Management** on your iPhone and trust your developer certificate
3. If running in the **Simulator**: select any iPhone simulator (note: camera won't work in simulator)
4. Press **⌘R** (or the ▶ Play button) to build and run

---

## Step 6 — Using Siri / Apple Intelligence

Once the app has been run at least once on your device, Siri phrases are automatically registered. No user setup needed.

**To use with Siri:**
- Say: *"Hey Siri, identify LEGO part with LEGO Sorter"*
- Siri will ask you to choose a photo
- It will identify the part and tell you what it is and where it's stored

**To use from Photos:**
- Open a photo of a LEGO part in the Photos app
- Tap the **Share** button
- Scroll down and tap **LEGO Sorter**
- The result appears without opening the app

**iOS 18.2+ Apple Intelligence:**
- Visual intelligence can suggest the LEGO Sorter action when your camera is pointed at a LEGO part

---

## Troubleshooting

**"No such module" errors** — make sure all `.swift` files were added to the LegoSorter target (select each file, check the Target Membership panel on the right).

**Build fails on `IntentFile.data`** — make sure your Deployment Target is set to iOS 16.0 or later. Go to project settings > General > Minimum Deployments.

**Camera not working** — camera requires a physical device; it does not work in the iOS Simulator.

**Siri says "App not available"** — open the app manually first so it registers the intents, then try Siri again.

**"Not signed in" from Siri** — open the app, log in, then use Siri. The intent reads your login token from the same secure storage the app uses.
