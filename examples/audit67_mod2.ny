# Fixture module for examples/vm_audit67.ny: imports another module itself.
import audit67_mod
from audit67_mod import helper

def twice(n):
    return [helper(n), audit67_mod.helper(n)]
