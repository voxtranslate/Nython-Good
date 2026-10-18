# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/xml/dom/NodeFilter.ny - xml.dom.NodeFilter (CPython 3.11).
# This is the Python mapping for interface NodeFilter from
# DOM2-Traversal-Range. It contains only constants.

class NodeFilter:
    FILTER_ACCEPT = 1
    FILTER_REJECT = 2
    FILTER_SKIP   = 3

    SHOW_ALL                    = 0xFFFFFFFF
    SHOW_ELEMENT                = 0x00000001
    SHOW_ATTRIBUTE              = 0x00000002
    SHOW_TEXT                   = 0x00000004
    SHOW_CDATA_SECTION          = 0x00000008
    SHOW_ENTITY_REFERENCE       = 0x00000010
    SHOW_ENTITY                 = 0x00000020
    SHOW_PROCESSING_INSTRUCTION = 0x00000040
    SHOW_COMMENT                = 0x00000080
    SHOW_DOCUMENT               = 0x00000100
    SHOW_DOCUMENT_TYPE          = 0x00000200
    SHOW_DOCUMENT_FRAGMENT      = 0x00000400
    SHOW_NOTATION               = 0x00000800

    def acceptNode(self, node):
        raise NotImplementedError
