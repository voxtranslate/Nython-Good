# nython: module    (a package: xml.etree, xml.parsers, xml.dom)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/xml - Python's xml package (round 79).
#
#   xml.etree.ElementTree   the ElementTree API (lib/xml/etree/ElementTree.ny)
#   xml.etree.ElementPath   its XPath subset
#   xml.parsers.expat       the pyexpat interface over Nython's own XML parser
#   xml.dom.minidom         the minimal DOM (parseString, toprettyxml ...)
#
# Not here: xml.sax and xml.dom.pulldom.
__all__ = ["dom", "parsers", "etree"]
