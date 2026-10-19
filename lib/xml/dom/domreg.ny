# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/xml/dom/domreg.ny - xml.dom.domreg (CPython 3.11): the registry of DOM
# implementations behind getDOMImplementation (minidom is the one there is).

# This is a list of well-known implementations.  Well-known names
# should be published by posting to xml-sig@python.org, and are
# subsequently recorded in this file.

import sys

well_known_implementations = {
    'minidom':'xml.dom.minidom',
    '4DOM': 'xml.dom.DOMImplementation',
    }

# DOM implementations not officially registered should register
# themselves with their

registered = {}

def registerDOMImplementation(name, factory):

    registered[name] = factory

def _good_enough(dom, features):
    for f,v in features:
        if not dom.hasFeature(f,v):
            return 0
    return 1

def getDOMImplementation(name=None, features=()):

    import os
    creator = None
    mod = well_known_implementations.get(name)
    if mod:
        mod = __import__(mod, {}, {}, ['getDOMImplementation'])
        return mod.getDOMImplementation()
    elif name:
        return registered[name]()
    elif not sys.flags.ignore_environment and "PYTHON_DOM" in os.environ:
        return getDOMImplementation(name = os.environ["PYTHON_DOM"])

    # User did not specify a name, try implementations in arbitrary
    # order, returning the one that has the required features
    if isinstance(features, str):
        features = _parse_feature_string(features)
    for creator in registered.values():
        dom = creator()
        if _good_enough(dom, features):
            return dom

    for creator in well_known_implementations.keys():
        try:
            dom = getDOMImplementation(name = creator)
        except Exception: # typically ImportError, or AttributeError
            continue
        if _good_enough(dom, features):
            return dom

    raise ImportError("no suitable DOM implementation found")

def _parse_feature_string(s):
    features = []
    parts = s.split()
    i = 0
    length = len(parts)
    while i < length:
        feature = parts[i]
        if feature[0] in "0123456789":
            raise ValueError("bad feature name: %r" % (feature,))
        i = i + 1
        version = None
        if i < length:
            v = parts[i]
            if v[0] in "0123456789":
                i = i + 1
                version = v
        features.append((feature, version))
    return tuple(features)
