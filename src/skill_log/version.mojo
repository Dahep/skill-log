"""The release version, baked in at build time.

The file this module is generated from carries the version as a constant,
so `scripts/build.sh` writes it from `SKILL_LOG_VERSION`, `git describe
--tags`, or the `0.0.0-dev` fallback. Nothing in the source tree holds a
tracked version constant: the version is a property of the build, not of
the checkout.
"""


def version() -> String:
    """The release version of this build."""
    return "0.0.0-dev"
