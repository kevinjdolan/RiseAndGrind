# TestFlight release guide

Rise & Grind uses automatic signing for Apple team `J3BZJ3LKTQ` and the bundle
identifier `com.kevin.riseandgrind.alarmkit`. The app requires iOS 26.1 or
later.

## One-time App Store Connect setup

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com/).
2. Open **Apps**, select the plus button, and choose **New App**.
3. Use these values:
   - Platform: iOS
   - Name: Rise & Grind
   - Primary language: English (U.S.)
   - Bundle ID: `com.kevin.riseandgrind.alarmkit`
   - SKU: `rise-and-grind-ios`
   - User Access: Full Access
4. If the bundle ID is not offered, create the explicit App ID first in
   [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
   using the same bundle identifier.

## Prepare and upload a build

The project is currently version `0.2.0` build `1`, which can be used for the
first upload if it has not already been uploaded. Every later upload needs a
new positive build number. From the repository root, increment the current
build number and regenerate the Xcode project:

```sh
./scripts/prepare_testflight_build.sh
```

To choose both numbers explicitly:

```sh
./scripts/prepare_testflight_build.sh 2 0.2.0
```

Then upload with Xcode:

1. Open `RiseAndGrind.xcodeproj`.
2. Select the **RiseAndGrind** scheme and **Any iOS Device (arm64)**.
3. Choose **Product > Archive**.
4. When Organizer opens, select the new archive and choose
   **Distribute App > App Store Connect > Upload**.
5. Keep automatic signing and symbol upload enabled.
6. Complete the upload and wait for App Store Connect to finish processing it.

For a command-line distribution-signing check without uploading, export an
archive to a directory outside the repository:

```sh
xcodebuild \
  -exportArchive \
  -archivePath /path/to/RiseAndGrind.xcarchive \
  -exportPath /tmp/RiseAndGrind-AppStore-Export \
  -exportOptionsPlist Config/AppStoreExportOptions.plist \
  -allowProvisioningUpdates
```

The app declares that it does not use non-exempt encryption, so App Store
Connect should not ask the export-compliance question for every build. Update
that declaration before shipping if encryption is added later.

## Configure external TestFlight testing

In App Store Connect:

1. Open **Apps > Rise & Grind > TestFlight**.
2. Under **Test Information**, enter:
   - Beta App Description: a short explanation of the alarm, calendar
     adjustment, and squat challenge.
   - Feedback Email: an address that is checked regularly.
   - Contact Information: the developer contact used by Beta App Review.
3. Create an external group named **Friends & Family**.
4. Add the processed build to that group.
5. Complete **What to Test** with the suggested text below.
6. Submit the build for Beta App Review. The first external build requires
   review; later builds may also be selected for review.
7. After approval, invite people by email or enable the group's public link.

Suggested **What to Test** text:

> Test onboarding, scheduling an isolated one-minute alarm, alarm delivery
> while the phone is locked, the wake challenge, squat calibration, calendar
> adjustment, and imported alarm sounds. Please report the iPhone model, iOS
> version, and whether the phone was locked when an alarm issue occurred.

Suggested **Beta App Review Notes**:

> Rise & Grind is an AlarmKit-based alarm app for iPhone running iOS 26.1 or
> later. No account or server is required. Calendar events, motion readings,
> microphone sound levels used by Squat Lab, settings, and diagnostics remain
> on the device unless the user explicitly shares a diagnostic file. To review
> without waiting overnight, complete onboarding and use the isolated
> one-minute alarm test in Setup. The audio background mode is used for active
> alarm and wake-challenge playback. The background refresh mode performs
> best-effort reconciliation of the user's next alarm plan.

## Invite friends

### Email invitations

1. Open the **Friends & Family** external group.
2. Select **Add Testers**.
3. Enter each friend's name and Apple Account email address.
4. Select **Invite**.

Each friend opens the invitation on their iPhone, installs Apple's
[TestFlight app](https://apps.apple.com/app/testflight/id899247664), accepts
the invitation, and installs Rise & Grind.

### Public link

1. Open the **Friends & Family** external group.
2. Select **Enable Public Link**.
3. Set a tester limit and optionally add device or OS criteria.
4. Copy the link and send it to friends.

Anyone who receives a public link may forward it. Disable the link or remove a
build from the group when testing should stop.

## Release rhythm

- A TestFlight build is available for at most 90 days.
- Upload a new build before the current one expires.
- Keep the marketing version unchanged for beta fixes if desired, but
  increment the build number for every upload.
- Testers update from the TestFlight app. Automatic updates can be enabled
  there.
- Use **TestFlight > Feedback** in App Store Connect to review screenshots,
  comments, crashes, and session information submitted by testers.
