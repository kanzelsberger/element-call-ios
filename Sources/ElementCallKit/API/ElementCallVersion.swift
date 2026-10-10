//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// The version of this package, for a call screen to show and a bug report to quote.
///
/// A constant is a compromise, and it is worth knowing why it exists rather than being derived.
/// SwiftPM tells a compiled module nothing about the version it was resolved at, and the package
/// has no bundle of its own to carry one — it is source, compiled into the host's binary. So there
/// is no runtime source to read. A build-tool plugin could not help either: the tag is what a host
/// resolves, and a plugin cannot see it.
///
/// **Nobody edits this by hand.** `scripts/release.sh` rewrites it in the same step that closes the
/// `## Unreleased` heading in CHANGES.md, so the value lands inside the commit the release tags —
/// which keeps the rule in AGENTS.md true, that there is nothing for a pull request to bump. The
/// script fails the release if the rewrite does not take.
///
/// On `main` between releases it therefore reads as the *previous* release. That is only ever wrong
/// for a build made from this repository rather than from a tag, and every consumer pins an exact
/// version, so what a host displays is the version it actually resolved.
@available(iOS 18, *)
public nonisolated enum ElementCallVersion {
    public static let current = "0.1.0-rc.9"
}
