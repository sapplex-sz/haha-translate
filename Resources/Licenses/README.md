# Third-party notices — HaHa翻译

This directory contains license and attribution material intended to ship with the app. The app's own name and artwork do not imply endorsement by any upstream project.

## Model weights

- Tencent Hy-MT2 1.8B: official model-card license is Apache-2.0. Full text is in `HyMT2.txt`, maintained by the model-integration task. Keep the corresponding model copyright/notice text if supplied upstream.
- Lightweight artifact: `tencent/Hy-MT2-1.8B-1.25Bit-GGUF`, revision `9df5c824a00a744fb0512a29c640466f4d97dfb0`, file `Hy-MT2-1.8B-1.25Bit.gguf`.
- Standard artifact: `tencent/Hy-MT2-1.8B-GGUF`, revision `a0c709d9fac510f2c807aa3af52872340dc37a4a`, file `Hy-MT2-1.8B-Q4_K_M.gguf`.
- Sources: [lightweight model](https://huggingface.co/tencent/Hy-MT2-1.8B-1.25Bit-GGUF), [standard model](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF).

## Inference runtime and other dependencies

The runtime task owns the complete license texts and source provenance for the exact shipped runtime, quantization support, and any bundled dependency. Do not treat this index as a substitute for those notices. Before archiving, reconcile this list with the actual linked libraries and copied resources; preserve required copyright notices, full license texts, and any NOTICE files.

## Release checks

- Model URLs, pinned revisions, byte counts, and SHA-256 values in the app must match the verified manifest.
- Include all actual runtime licenses in the final app resources, not only in the source repository.
- Provide an in-app way to view third-party notices or open the bundled notices.
- Do not copy competitor application code, icons, screenshots, or trademarks into the product without the applicable license and rights review.

This index records the intended attribution inventory. Final Archive verification is recorded in `docs/ReleaseReadiness.md`.
