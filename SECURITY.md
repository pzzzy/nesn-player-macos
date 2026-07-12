# Security

Report vulnerabilities privately through GitHub Security Advisories rather than a public issue.

The application intentionally reads only the official NESN app's local token plist and cached entitlement request metadata. It must not log or upload authorization tokens, personalized stream URLs, FairPlay authorization headers, SPC/CKC bodies, account identifiers, or viewing history.

Do not attach Charles sessions, logs containing tokens, or account data to public issues. Revoke exposed sessions by signing out of NESN 360 and signing in again.

The release is ad-hoc signed for local integrity, not notarized by Apple. Review and build from source if that is preferable.
