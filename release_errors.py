"""Shared operational errors for imported and script-invoked release commands."""


class ReleaseError(RuntimeError):
    """The release cannot proceed safely; show the reason without a traceback."""
