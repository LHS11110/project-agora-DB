# Third-party notices and vendor terms

The configuration/scripts in this repository are MIT licensed. Vendor database images, plugins, models and management tools retain their own terms; the repository LICENSE does not relicense them.

| Component observed 2026-10-31 | Applicable review |
| --- | --- |
| SQL Server 2022 CU27, configured Express | Microsoft SQL Server license terms. Express is the selected edition; retain vendor terms and review any edition change. Developer edition is for non-production development/testing. |
| Redis 8.6.7 | Choose and comply with an offered license: RSALv2, SSPLv1 or AGPLv3. Do not label Redis 8 BSD-licensed. The current use is an internal application cache, not a public Redis database service. Reassess when packaging or exposing a database service. |
| Elasticsearch 8.19.22 official image + analysis-nori | Official distribution terms and bundled LICENSE/NOTICE apply. Do not assume the official binary distribution is Apache-2.0 merely because some source files offer an open-source alternative. Review ELv2 restrictions before a managed Elasticsearch offering. |
| Redis Insight 3.8.0 | Separate vendor license; review that image's included terms and digest before redistribution. |

Primary references: [Microsoft SQL licensing](https://www.microsoft.com/licensing/guidance/SQL), [Redis licenses](https://redis.io/legal/licenses/), [Elastic licensing](https://www.elastic.co/licensing/elastic-license/faq).

The current Compose configuration pulls vendor images; it does not include their binaries in Git. If publishing images or database snapshots, retain all image notices and review the corresponding vendor and copyleft obligations. This document is an inventory and review guide, not an assertion that every future deployment/distribution is compliant.
