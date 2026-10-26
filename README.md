# Capri for Mac

An unofficial animated desktop companion for macOS. Capri rests as a star, opens into an animated chat window, and can use your ChatGPT account and an ElevenLabs voice you configure. A full-body appearance is also available.

**Bring your own accounts.** The app contains no shared ChatGPT session, API key, or hosted billing service. Your ChatGPT requests use your account's available plan allowance or credits; ElevenLabs speech uses your ElevenLabs account. Downloading Capri does not give anyone access to the maintainer's accounts or usage.

## Download and open

1. Open [Releases](https://github.com/spiermar2/capri-for-mac/releases/latest) and download the Mac app ZIP from a release's **Assets** list.
2. Unzip it and move **Capri for Mac.app** into your Applications folder. Keep one installed copy.
3. Open the app. This build requires **macOS 26 or later and Apple silicon (arm64)**; it does not support Intel Macs.

The app is **ad-hoc signed**, not signed with an Apple Developer ID or notarized by Apple. macOS may block its first launch. If you trust the downloaded release, use **System Settings → Privacy & Security → Open Anyway** when offered, then confirm. Do not disable Gatekeeper system-wide. [Apple's instructions](https://support.apple.com/en-us/102445)

## Connect ChatGPT

1. Right-click Capri or use her menu-bar icon, then open **Settings**.
2. Under **BRAIN**, select **ChatGPT · your plan** and open **ChatGPT account…**.
3. Click **Continue with ChatGPT** and sign in to **your own account** in the browser. Review and approve the requested access there.
4. Choose a model available to your account. **Refresh models** checks your current access; **Manage usage** opens the account's usage controls.

The default model preference is GPT-6.1 Sol. Account eligibility, models, limits and Fast processing depend on OpenAI's availability and your account; access is not guaranteed by this app. Fast processing is requested for that model without reducing its default reasoning level. The status distinguishes **Fast requested** from the processing tier actually reported by the service.

ChatGPT sign-in does not require entering an OpenAI API key. It does send submitted messages and recent conversation context to OpenAI. Other ChatGPT conversations are not imported. [Privacy details](PRIVACY.md)

Optional local alternatives are **Apple Intelligence** on a compatible, enabled Mac, or an already installed **Ollama** model served locally on port 11434. Capri does not install models for you.

## Set up a voice with ElevenLabs

Voice setup is separate from ChatGPT. Use your own ElevenLabs account, API key and a voice your account can use. Voice Design can create a voice from text; no recording or voice clone is required, and it does not guarantee the show's original performance.

1. In ElevenLabs, open **Voices → My Voices → Add a new voice → Voice Design**. Paste the design prompt below, add preview text, generate the options, and save the one you prefer. Generation and saved-voice availability depend on your ElevenLabs plan. [Voice Design guide](https://elevenlabs.io/docs/eleven-creative/voices/voice-design)
2. Find the saved voice in **My Voices**, open its **More actions (…)** menu and choose **Copy voice ID**. [Find a voice ID](https://elevenlabs.io/docs/help-center/technical/how-do-i-find-the-voice-id-of-my-voices-via-the-website-and-api)
3. Open **Developers → API Keys** in ElevenLabs and create a key for your account. Grant **Text to Speech** access and ensure the selected voice is available to that account. Keep the key restricted to the features you need; you can also set a credit limit. Copy the key when it is created. [API-key instructions](https://elevenlabs.io/docs/help-center/technical/how-do-i-authorize-myself-using-an-api-key)
4. In Capri's **Settings → VOICE**, select **Capri · ElevenLabs**, paste your key into the secure field and click **Save key**. Replace **Voice ID** with the ID you copied, then click **Test voice**.
5. Enable **Speak replies** for spoken answers. Speech plays as audio arrives; a short service startup delay may remain. The voice test and spoken replies consume your ElevenLabs allowance or credits.

The following is the **user-supplied Voice Design prompt**, preserved verbatim. It is a creative description, not a verified description of the original performer:

> cybernetic hologramic sounding woman playful voice is light, bright, and buoyant, with a lilt that lifts at the ends of her phrases as though she’s teasing or in on a joke only she understands. Her pacing is quick and bouncy, slipping between mock-innocent sweetness and a sly, knowing edge that keeps listeners slightly off balance. She sounds close and airy, almost whispered into the ear, which suits an AI construct who exists only inside the heads of those who plug in her chip, and a faint digital sheen, a flicker of glitch or shimmer, tends to creep in when her mischief sharpens. Beneath the performance, the act can crack, letting a quieter, more vulnerable tone slip through that hints at the Project Capricorn past she can’t quite escape. Note that this is an inference from the character’s role rather than a verified description of the actual performance, so it’s worth checking against the show itself.

You can instead select **Mac system voice**, or turn **Speak replies** off. Neither option needs an ElevenLabs key. A voice ID identifies a voice; it is not an API key and does not grant access to another person's account.

## Controls

| Control | Action |
| --- | --- |
| Tap **right Command (⌘)** | Summon Capri; tap again to return her to the dormant star |
| **Option–Command–C (⌥⌘C)** | Alternate summon/dormant shortcut |
| **Control–Option–Command–C (⌃⌥⌘C)** | Hide or restore Capri completely, including the star |
| Click the star | Open her screen |
| **Escape** or **×** | Collapse the screen |
| Drag Capri | Move her |
| Right-click | Open the menu |
| Click the microphone | Start dictation; review the text and press Return to send |

Use **Settings → Enable shortcut…** to grant Accessibility access for right Command while another app is focused. Replacing or rebuilding an ad-hoc signed app can require refreshing its Accessibility or Keychain approval.

**Idle animations** run locally and consume no ChatGPT or ElevenLabs usage. They pause during interaction. **Settings → LOOK** switches between **Star + screen** and **Full-body companion**. In full-body mode, double-click to pat her or drop her above a visible window to perch; **Window interactions** can be disabled separately.

## Privacy and usage

Credentials are saved in the local macOS Keychain, not in the repository or app bundle. There is no maintainer-operated relay or shared credential fallback. Each person supplies their own authorization and is responsible for their own usage. Ordinary idle animations do not contact either AI provider; sent chat requests, voice generation, account authorization and account/model checks may make network requests.

Capri does not keep a local chat archive or import other ChatGPT chats. It does not read window contents or typing in other apps. The microphone is activated only through its explicit control. See [PRIVACY.md](PRIVACY.md) for data flows and account removal.

## Build from source

Use Apple silicon with macOS 26 or later and a Swift 6 toolchain/macOS 26 SDK, such as the appropriate Xcode Command Line Tools.

```sh
git clone https://github.com/spiermar2/capri-for-mac.git
cd capri-for-mac
./build.sh
```

The app is written to `.build.noindex/Capri for Mac.app`. The script signs it ad hoc; it does not notarize it. Build outputs are intentionally excluded from Git. Avoid keeping launched test copies scattered around normal folders, because macOS can register them as separate Apps entries.

## Verify the build

Run the offline regression suite with:

```sh
./run-tests.sh
```

These tests use synthetic credentials and intercepted network requests; they do not read your Keychain or spend AI/voice credits. Auth checks use a temporary loopback listener, and audio checks exercise muted local playback.

## Credits and license

This is an unofficial fan project and is not affiliated with OpenAI, ElevenLabs, Apple, CD PROJEKT RED, Studio Trigger or Netflix.

Original Mac code and the locally generated app icon use the [MIT license](LICENSE). Character artwork and the bundled font have separate rights and are **not** covered by that MIT license. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for sources, credits and license boundaries.
