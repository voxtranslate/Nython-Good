# nython: module    (import it by name: it runs in a module scope of its own)
# lib/nyxai - the parts of NyxAI, the programming agent lib/aiagent.ny puts
# together (round 82). Each works on its own:
#
#     nyxai.facts    ProgramModel: per-function facts from the real parser
#                    (ny_facts), the call graph, the import graph
#     nyxai.index    WorkspaceIndex: BM25F retrieval over code and documents,
#                    structure-aware boosts, incremental, saved as JSON
#     nyxai.rules    RuleEngine: forward chaining over facts with variables,
#                    stratified negation, why() explanations
#     nyxai.review   Reviewer: review rules that analyse the program, the
#                    mechanical fixes as a diff (fix_text)
#     nyxai.testgen  TestGenerator: unittest modules from signatures,
#                    doctests and observed behaviour (subprocess, timeout,
#                    boundary and random inputs, shrinking)
#     nyxai.docgen   draft_docstring: Args / Returns / Raises from the facts
#
# Everything is offline and deterministic: no model to download, no network.

from nyxai.facts import ProgramModel, FunctionInfo, ClassInfo, ModuleInfo, parse_facts, default_rules
from nyxai.index import WorkspaceIndex, Hit, terms_of, stem
from nyxai.rules import RuleEngine, Rule
from nyxai.review import Reviewer, Finding, fix_text, apply_edits, unified_diff_text
from nyxai.testgen import TestGenerator, TestGenResult
from nyxai.docgen import draft_docstring, docstring_edit

__all__ = ["ProgramModel", "FunctionInfo", "ClassInfo", "ModuleInfo", "parse_facts", "default_rules",
           "WorkspaceIndex", "Hit", "terms_of", "stem", "RuleEngine", "Rule", "Reviewer", "Finding",
           "fix_text", "apply_edits", "unified_diff_text", "TestGenerator", "TestGenResult",
           "draft_docstring", "docstring_edit"]
