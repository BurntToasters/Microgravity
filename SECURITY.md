# Security policy

## Supported versions

Security fixes target the latest release and the `main` branch. Please update to the latest release before reporting an issue.

| Version | Supported |
| --- | --- |
| 0.2.x | Yes |
| Older than 0.2 | No |

## Reporting a vulnerability

Do not open a public GitHub issue for a security vulnerability.

Use GitHub's private vulnerability reporting for this repository:

<https://github.com/BurntToasters/Microgravity/security/advisories/new>

If that form is unavailable, use <https://help.rosie.run/contact> and ask for a private reporting channel without including exploit details in the first message.

Please include, when possible:

- The affected Microgravity version and build number (shown in Settings), plus the macOS version and Mac architecture.
- A description of the impact and the affected component, such as the app, privileged helper, update path, or release tooling.
- Reproduction steps or a minimal proof of concept.
- Relevant logs with personal information, credentials, and other secrets removed.

## Scope

In scope:

- The Microgravity app and its process, system, history, and inventory features.
- The privileged helper, including installation, code-signing checks, authorization, process termination, and sample handling.
- The update path, release signatures, and published release artifacts.
- Build and release scripts that affect shipped artifacts or credentials.
- Local data handling, including the history database and helper audit logs.

Out of scope:

- Vulnerabilities in macOS or other Apple software.
- Vulnerabilities in Sparkle itself. Report those to the Sparkle project, and include the Microgravity version if the issue affects this integration.
- Issues that require an attacker to already have root access, physical access to an unlocked Mac, or control of the user's account.
- Social engineering and denial-of-service reports that do not demonstrate a security boundary bypass.

## Response expectations

This is a volunteer-maintained project. The maintainer will aim to:

- Acknowledge a complete report within 3 business days.
- Provide an initial assessment within 10 business days.
- Keep the reporter informed of meaningful progress and coordinate disclosure timing.

These are best-effort targets, not a guaranteed service-level agreement. A fix may depend on the complexity of the issue and upstream fixes.

## Testing and disclosure

- Test only on a Mac you own or have explicit permission to test.
- Do not access other users' data, disrupt services you do not own, or run destructive tests against someone else's machine.
- Give the maintainer a reasonable opportunity to investigate and release a fix before public disclosure.
- Do not include secrets, personal data, or third-party data in a report.
