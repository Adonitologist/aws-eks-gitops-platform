# Security policy

This is a portfolio project maintained by one person on a best-effort basis. There is no supported release and no service level.

## Reporting a problem

- If the GitHub Security tab offers "Report a vulnerability" for this repository, use it. Private vulnerability reporting was not enabled when this file was written.
- Otherwise open an issue and describe the problem without sensitive details (no credentials, account data or exploit steps); the owner will follow up.

## What is not in this repository

- No credentials, access keys, passwords or private keys.
- No account ids in text, except inside resource names that Terraform needs (the state bucket name; see ADR 0001, "Addendum 2026-10-12: account id in the state bucket name").

## Scope

Terraform, Helm values and Kubernetes manifests in this repository, and the scripts under `scripts/`. The AWS account, the operator's workstation and third-party charts and images are out of scope.
