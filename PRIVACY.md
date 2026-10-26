# Privacy and account usage

Capri is a native desktop app. It has no maintainer-operated server, analytics service, shared ChatGPT account or shared ElevenLabs API key. Credentials and account usage belong to the person who configures the app on their Mac.

## Data sent from your Mac

| Feature | Data and destination |
| --- | --- |
| ChatGPT sign-in | The browser authenticates with OpenAI. A temporary loopback listener on `127.0.0.1` receives the sign-in callback; it is not a public network server. Capri stores the resulting account registration and credentials locally. |
| ChatGPT replies | Your submitted message, bounded recent conversation, quoted context from that conversation and Capri's character instructions are sent directly to OpenAI's API. Model availability checks and credential refresh/revocation also contact OpenAI. |
| ElevenLabs speech | The words being spoken, selected voice/model settings and your API-key authorization are sent directly to ElevenLabs. This includes **Test voice**. Returned audio is streamed into playback. |
| Microphone dictation | Starts only when you use the microphone control. Recognition requires on-device support; Capri does not fall back to Apple's server recognition. Review the resulting text before submitting it to the selected chat backend. |
| Apple Intelligence | Uses the on-device Foundation Models framework when available and enabled. |
| Ollama | Sends conversation data to the local Ollama endpoint at `127.0.0.1:11434`. You install and manage that model and service. |
| Explicit open/search commands | A recognized command can open an application or a search URL in your browser. The destination service then handles that request normally. |

The OpenAI request sets `store` to `false`. This is a request option, not a promise about all provider retention or security logging. OpenAI and ElevenLabs process requests under their own terms, privacy policies and account settings. Review those policies for provider-side retention and usage rules.

## What stays on your Mac

- **ChatGPT credentials:** macOS Keychain stores authentication tokens, verified account/client information and the app's local registration identifier. Keychain synchronization is disabled for this item.
- **ElevenLabs key:** macOS Keychain stores the key you enter. Keychain synchronization is disabled for this item. The key is not placed in ordinary preferences or bundled with the app.
- **Preferences:** macOS preferences store choices such as appearance, size, position, model, voice ID and whether voice or interactions are enabled. A voice ID is an identifier, not a credential.
- **Conversation:** recent messages and short dialogue context are kept in memory. Capri does not write a persistent local chat archive. Resetting the conversation or quitting clears that in-memory conversation.

Idle animations are local. They do not send prompts or generate speech. Merely typing an unsent draft does not submit a ChatGPT request. Hiding Capri is a display action and should not be treated as cancellation of a request already submitted.

## Desktop and microphone access

The right Command shortcut uses Accessibility permission to observe key/modifier state. The shortcut handler does not collect text typed in other apps. Window interactions read visible-window geometry to position Capri; they do not read titles, capture screenshots or send window contents to a model. The microphone is not always listening.

## Account separation and charges

The distributed app and source contain no maintainer authentication tokens, saved browser session or API key. Each installation connects using its own user's authorization. There is no backend that bills requests to the maintainer and no fallback to a maintainer account when sign-in or voice access fails.

ChatGPT usage is governed by the signed-in account's eligible plan allowance or credit balance. ElevenLabs uses the account associated with the API key entered by the user. Provider plans, model access, voice access, limits and pricing can change; Capri does not promise unlimited or free provider usage.

## Disconnect or remove credentials

- In **Settings → ChatGPT account…**, choose **Sign out**. Capri clears the active connection's local tokens and attempts remote revocation. A failed remote revocation is reported; the account registration mapping remains in Keychain for reconnection. You can also review and revoke connected access in ChatGPT account settings.
- In **Settings → VOICE**, choose **Forget key** to delete Capri's saved ElevenLabs API key. You can separately revoke that key in ElevenLabs.
- Turn off **Speak replies**, select **Mac system voice**, or choose a local brain to change which optional services are used.
- Deleting the app alone does not necessarily remove macOS Keychain items or preferences. Remove saved connections first if you want to clear them.

Never attach credentials, authentication callbacks, Keychain exports or private conversation logs to a public issue. Share the visible error category and a redacted description of how to reproduce it.
