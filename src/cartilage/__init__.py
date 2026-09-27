"""
Cartilage OS (Legacy Compatibility Shim for KUROGANE).
All modules and functionality have migrated to the 'kurogane' package.
"""

from kurogane import (  # noqa: F401
    builder,
    cli,
    composer,
    flasher,
    runner,
    schema,
    yaml,
)

__version__ = "4.0.1"

