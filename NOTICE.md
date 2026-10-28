# Notice

**Confidential.** This kit is provided by Evenfire to your organisation for
installing and operating the Evenfire platform on your own GKE cluster. Do not
redistribute it outside your organisation without Evenfire's written consent.

| | |
|---|---|
| Targets platform release | **v0.12.0** of the open-source `evenfire-ai/evenfire` repo; use this kit's matching tag (`gke-kit-v0.12.0`) |
| Start here | [README.md](README.md) |
| Validated | offline: the overlay template renders against the release and passes the platform's NetworkPolicy and workload-hardening linters; scripts are tested against simulated clusters |
| Not validated by Evenfire | a full install on *your* cluster; items marked **verify** in the guide (Google-side behaviour such as Dataplane V2, GCLB health-check ranges, private-cluster flags) |
| Sizing | indicative starting points, not requirements |
| Questions and issues | open an issue in this repository, or contact your Evenfire representative |

Updates are published as new `gke-kit-vX.Y.Z` tags. Before upgrading, read the
upgrade checks in [02 › Keeping the overlay honest](02-assembly-and-overlay-structure.md#keeping-the-overlay-honest-over-time).
