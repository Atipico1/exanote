import importlib.util
from pathlib import Path
import pytest
spec = importlib.util.spec_from_file_location('release_version', Path(__file__).parents[1] / 'scripts/release_version.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

def test_first_and_next_patch():
    assert m.choose_version('0.1.1', ['v0.1.0']) == '0.1.1'
    assert m.choose_version('0.1.1', ['v0.1.1', 'v0.1.2']) == '0.1.3'

def test_explicit_version_and_source_minimum():
    assert m.choose_version('0.2.0', ['v0.1.9']) == '0.2.0'
    assert m.choose_version('0.1.1', ['v0.1.1'], 'v1.0.0') == '1.0.0'
    for version in ['0.1.1', '0.1.0', '0.01.2', '1.2', '1.2.3-rc1']:
        with pytest.raises(ValueError):
            m.choose_version('0.1.1', ['v0.1.1'], version)
