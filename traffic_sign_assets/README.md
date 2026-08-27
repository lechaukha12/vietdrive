# Vietnamese traffic sign assets

This is a curated candidate pack for VietDrive. The legal reference is QCVN
41:2024/BGTVT, effective from 1 January 2025. Source SVG files come from
Wikimedia Commons. The app catalog uses lossless Wikimedia thumbnails; original
SVG URLs remain recorded in the manifest and may be cached separately.

The fetcher rejects any file whose Commons API metadata does not report Public
domain. It writes source URLs, page URLs, license metadata and SHA-256 hashes to
manifest.json, then imports the images into the Xcode asset catalog.

Run:

    python3 fetch_assets.py

Important: public-domain status is a reuse check, not proof that every drawing
matches the latest regulation. Every asset remains marked as a candidate until
visually compared against the official QCVN 41:2024/BGTVT annex.
