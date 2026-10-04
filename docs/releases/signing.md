# Signing and privacy grants

Recommendation: for this personal utility collection, the cheapest stable signing
option is **one persistent self-signed code-signing identity**, backed up and reused
by local builds and CI. Treat that as a proposal requiring the user's decision;
this branch does not create/import certificates or change signing secrets. The
artifact builder currently uses ad hoc signing, as today's local installers do.

macOS privacy permission continuity follows the app's **designated requirement**
(DR). Apple explicitly describes microphone permissions being stored against the
DR and checked when an updated app accesses the microphone. An ad hoc signature
identifies only the exact signed program, so rebuilding under the same bundle ID
and path does not establish a stable signing identity. This explains why QR Reader
can need Screen Recording again after an update; it is an inference from Apple's
identity model, not a TCC test performed by this branch. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[Code Signing Requirement Language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html).

| Option | Cost | Permission continuity | Distribution |
| --- | --- | --- | --- |
| Ad hoc (`codesign --sign -`) | Free | New builds have a new identity; grants can need renewal | No notarization; manual Gatekeeper approval may be needed |
| Persistent self-signed identity | No Apple fee | Stable certificate + bundle ID can establish the same DR across builds; validate each protected service on the target macOS | Does not provide Apple-recognized developer identity or notarization |
| Developer ID + notarization | Apple Developer Program: US$99/year, regional pricing may vary | Stable developer identity and compatible DRs support permission continuity | Apple-supported distribution outside the App Store; normal Gatekeeper path |

Apple documents that self-signed identities can identify continuity between
versions, but do not establish the publisher's identity through a recognized CA.
Gatekeeper has stricter trust requirements than subsystems that check signing
continuity. [Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html),
[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/).
Developer ID/notarization is available through the paid program;
[Apple's membership comparison](https://developer.apple.com/support/compare-memberships/)
and [Developer ID certificate guidance](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
cover eligibility and pricing (checked 2026-10-03).

If approved, persist the same private key/certificate as protected CI secrets,
import it into a temporary build keychain, sign every executable and bundle with
consistent identifiers and requirements, verify, then delete that keychain. Do
not create a new certificate on each runner. Avoid broad custom requirements
that accept any code carrying the same identifier. Developer ID additionally
requires hardened runtime/appropriate entitlements, notarization and stapling;
those need per-app verification, especially microphone and screen capture apps.

Changing from existing ad hoc installs to either stable option will likely require
**one fresh permission grant**. Keep application paths and bundle identifiers
unchanged, but do not promise that existing TCC grants can be adopted. Do not edit
or reset the user's TCC database. A self-signed certificate's replacement also
needs a planned requirement migration; preserve its private key and certificate.

Before distributing permission-sensitive apps, compare two different builds:

```sh
codesign -d -r- '/path/to/first.app'
codesign -d -r- '/path/to/second.app'
codesign --verify --strict '/path/to/second.app'
```

Then authorize the first build in an isolated macOS account/VM, install the second
at the same path, and exercise both Screen Recording and Microphone. The isolated
home installer tests prove filesystem preservation only; they do not prove TCC
continuity, which requires a real login session and the chosen signing identity.
