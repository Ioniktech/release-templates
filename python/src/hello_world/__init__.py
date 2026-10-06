"""A hello-world package whose only job is to be released to PyPI."""

from .version import __version__


def greeting(name: str = 'world') -> str:
    return f'Hello, {name}!'


__all__ = ['__version__', 'greeting']
