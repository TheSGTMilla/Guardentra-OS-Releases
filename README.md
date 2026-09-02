# Guardentra OS Releases

Public release channel for Guardentra OS installation media and update artifacts.

This repository intentionally contains **release artifacts and metadata only**. Guardentra OS source and engineering material remain in the private `TheSGTMilla/Guardentra-OS` repository.

## Release channels

Initial channel: `pilot`

Future channels may include:
- Stable
- Pilot
- Beta
- Developer

## Installation media naming

Use this format for bootable installation images:

`guardentra-os-<version>-amd64.iso`

Each ISO must have a matching SHA-256 file:

`guardentra-os-<version>-amd64.iso.sha256`

Example:

- `guardentra-os-0.6-pilot-amd64.iso`
- `guardentra-os-0.6-pilot-amd64.iso.sha256`

## In-place update naming

Use this format for staged OS update bundles:

`guardentra-os-update-<version>-amd64.tar.zst`

Each bundle must have a matching SHA-256 file:

`guardentra-os-update-<version>-amd64.tar.zst.sha256`

## Security

Guardentra OS clients must verify checksums before staging updates. Automatic update application remains disabled during the pilot until cryptographic release signing and rollback protection are implemented.

Do not publish private source code, credentials, signing private keys, or GitHub access tokens in this repository.
