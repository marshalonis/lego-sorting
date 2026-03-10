# LEGO Sorter — Improvements & TODOs

## iOS App

- [ ] **Image identification progress** — show upload progress indicator; identification can be slow with no feedback beyond the spinner
- [ ] **Auto-identify after photo** — after taking/selecting a photo, identification starts automatically (already done) but camera sheet dismiss is slightly laggy; investigate
- [ ] **Delete part** — add delete option from Browse view and drawer detail view
- [ ] **Delete drawer** — add delete option from drawer detail sheet
- [ ] **Drawer slot tap** — tapping an empty drawer slot in the grid should pre-fill the Add Drawer form with that cabinet/row/col
- [ ] **Siri integration** — test and verify Siri/Apple Intelligence identify intent works on device
- [ ] **TestFlight / App Store** — set up distribution so other users can install without Xcode

## Web App

- [ ] **Camera fix** — web still uses `<input type="file">` which doesn't offer camera/library choice on all browsers; consider splitting into two buttons like the iOS app

## Backend / Data

- [ ] **Project management** — rename project, leave project, delete project
- [ ] **Onboarding** — first-time user flow: prompt to create a project and first drawer after login
- [ ] **Parts catalog download progress** — show progress bar or streaming status instead of a single button with no feedback
- [ ] **User management** — admin view to list/deactivate Cognito users without needing AWS Console

## Sets & Minifigures (new feature)

- [ ] **Set search** — search Rebrickable by set name or number, view set details (year, theme, part count, image)
- [ ] **Have / Need breakdown** — for any set, show which parts are already in the catalog vs. still needed
- [ ] **Catalog a set** — mark a set as owned (stored per project, separate from individual parts)
- [ ] **Catalog minifigures** — track owned minifigures independently or linked to a set
- [ ] **My Sets view** — list of owned sets with swipe-to-delete
- [ ] **Rebrickable API key** — store in AWS SSM Parameter Store; add IAM permission to Lambda
- [ ] **S3 cache for set parts** — cache Rebrickable set parts lists in S3 (7-day TTL) to stay within 1000 req/day free tier limit
- [ ] **Rebrickable quota guard** — track daily API call count in DynamoDB; return 429 if approaching limit

## Infrastructure

- [ ] **Cost monitoring** — set up AWS budget alert for Bedrock usage
- [ ] **Image lifecycle** — verify S3 images bucket lifecycle policy is working (1-day expiry)
