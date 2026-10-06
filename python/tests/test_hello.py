import re

import hello_world
from hello_world.__main__ import main


def test_default_greeting():
    assert hello_world.greeting() == 'Hello, world!'


def test_named_greeting():
    assert hello_world.greeting('Ioniktech') == 'Hello, Ioniktech!'


def test_version_is_pep440():
    assert re.fullmatch(r'\d+\.\d+\.\d+', hello_world.__version__)


def test_cli_prints_greeting(capsys):
    assert main([]) == 0
    assert capsys.readouterr().out == 'Hello, world!\n'


def test_cli_version_flag(capsys):
    assert main(['--version']) == 0
    assert capsys.readouterr().out.strip() == hello_world.__version__
