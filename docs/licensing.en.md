# Community Edition Licensing & Distribution Boundaries

[中文](licensing.zh.md)

**The code in this repository is under the [Apache License 2.0](../LICENSE) (third-party
components are listed in [NOTICE](../NOTICE)).** Model weights are not distributed with the
repository and remain bound by their own licenses (see the table below).

## Verified upstream statements

Source: [sharky172/manga-light-colorizer model card](https://huggingface.co/sharky172/manga-light-colorizer#license) (the License section follows the wording of its README).

| Component | License | Notes |
|---|---|---|
| Model weights | [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) | Non-commercial optional backend; not distributed with the source code — users download it themselves |
| Upstream inference code | [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) | Attribution retained; the local service.py is an independent implementation, and its similarity to the upstream code is pending audit |
| Original code in this repository | Apache-2.0 | See LICENSE / NOTICE; calling the NC weights does not change the weights' own license |
| Material Web | Apache-2.0 (see the LICENSE in the installer package) | Third-party licenses retained; building the frontend does not change the model weights' license |

Uploading to GitHub, free sharing, and non-commercial application integration are not, in
themselves, commercial use. However, "free" does not necessarily satisfy NC: ad-monetized
products, commercial promotion, paid services, and the like should have their authorization
confirmed separately.

## User obligations

- Read the full license before using an NC-restricted model; "non-commercial" is neither a
  liability waiver nor a license for the manga copyright.
- When distributing weights, retain the attribution, source, and license information; modifying
  licensed material additionally involves change-marking and the ShareAlike terms.
- Independent code that calls the model, and the generated results, should not be simplistically
  lumped into the same license; the original manga copyright and the specific terms still need to
  be checked.
- Do not advertise this repository's open-source status as meaning the model is licensed for
  commercial use.
- The license acknowledgment in the frontend is only a reminder; it does not replace the full
  license.

## Still required before public release

1. Verify the provenance of the local inference code, as well as the provenance and license chain
   of the base model / accompanying weights. This page only records the publisher's statements
   about the material in this repository; it is not a complete legal audit.
2. Do not commit models/, out/, real manga, logs, virtual environments, or local proxy
   configurations. Public examples must use separately chosen material with clearly defined
   licensing.
3. Retain the license notices of npm/Python/Dart dependencies; before releasing binary packages,
   check the third-party material they contain.

Current positioning: Apache-2.0 code + NC weights downloaded by the user; a complete legal audit
of the license chain is still pending.
