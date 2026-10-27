# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/graphlib.ny - Python's graphlib (3.11): topological sorting of a graph
# of hashable nodes (CPython's Lib/graphlib.py algorithm, so the same graph
# gives the same order).
#
#     from graphlib import TopologicalSorter, CycleError
#     ts = TopologicalSorter({"b": {"a"}, "c": {"a", "b"}})
#     list(ts.static_order())             # ['a', 'b', 'c']
#
#     ts = TopologicalSorter(graph)       # or ts.add(node, *predecessors)
#     ts.prepare()                        # CycleError if there is a cycle
#     while ts.is_active():
#         for node in ts.get_ready():     # nodes whose predecessors are done
#             ...                         # (hand them to workers)
#             ts.done(node)
#
# TopologicalSorter: add, prepare, is_active (and bool()), get_ready, done,
# static_order, TopologicalSorter[int] (a generic alias). CycleError is a
# ValueError whose args[1] is the cycle found, its first node repeated at
# the end (["a", "b", "a"]). Errors and messages are CPython's.
#
# Everything graphlib has is here.
from types import GenericAlias

__all__ = ["TopologicalSorter", "CycleError"]

_NODE_OUT = -1
_NODE_DONE = -2


class _NodeInfo:
    __slots__ = "node", "npredecessors", "successors"

    def __init__(self, node):
        # The node this class is augmenting.
        self.node = node

        # Number of predecessors, generally >= 0. When this value falls to 0,
        # and is returned by get_ready(), this is set to _NODE_OUT and when the
        # node is marked done by a call to done(), set to _NODE_DONE.
        self.npredecessors = 0

        # List of successor nodes. The list can contain duplicated elements as
        # long as they're all reflected in the successor's npredecessors attribute.
        self.successors = []


class CycleError(ValueError):

    pass


class TopologicalSorter:

    def __init__(self, graph=None):
        self._node2info = {}
        self._ready_nodes = None
        self._npassedout = 0
        self._nfinished = 0

        if graph is not None:
            for node, predecessors in graph.items():
                self.add(node, *predecessors)

    def _get_nodeinfo(self, node):
        if (result := self._node2info.get(node)) is None:
            self._node2info[node] = result = _NodeInfo(node)
        return result

    def add(self, node, *predecessors):
        if self._ready_nodes is not None:
            raise ValueError("Nodes cannot be added after a call to prepare()")

        # Create the node -> predecessor edges
        nodeinfo = self._get_nodeinfo(node)
        nodeinfo.npredecessors += len(predecessors)

        # Create the predecessor -> node edges
        for pred in predecessors:
            pred_info = self._get_nodeinfo(pred)
            pred_info.successors.append(node)

    def prepare(self):
        if self._ready_nodes is not None:
            raise ValueError("cannot prepare() more than once")

        self._ready_nodes = [
            i.node for i in self._node2info.values() if i.npredecessors == 0
        ]
        # ready_nodes is set before we look for cycles on purpose:
        # if the user wants to catch the CycleError, that's fine,
        # they can continue using the instance to grab as many
        # nodes as possible before cycles block more progress
        cycle = self._find_cycle()
        if cycle:
            raise CycleError(f"nodes are in a cycle", cycle)

    def get_ready(self):
        if self._ready_nodes is None:
            raise ValueError("prepare() must be called first")

        # Get the nodes that are ready and mark them
        result = tuple(self._ready_nodes)
        n2i = self._node2info
        for node in result:
            n2i[node].npredecessors = _NODE_OUT

        # Clean the list of nodes that are ready and update
        # the counter of nodes that we have returned.
        self._ready_nodes.clear()
        self._npassedout += len(result)

        return result

    def is_active(self):
        if self._ready_nodes is None:
            raise ValueError("prepare() must be called first")
        return self._nfinished < self._npassedout or bool(self._ready_nodes)

    def __bool__(self):
        return self.is_active()

    def done(self, *nodes):

        if self._ready_nodes is None:
            raise ValueError("prepare() must be called first")

        n2i = self._node2info

        for node in nodes:

            # Check if we know about this node (it was added previously using add()
            if (nodeinfo := n2i.get(node)) is None:
                raise ValueError(f"node {node!r} was not added using add()")

            # If the node has not being returned (marked as ready) previously, inform the user.
            stat = nodeinfo.npredecessors
            if stat != _NODE_OUT:
                if stat >= 0:
                    raise ValueError(
                        f"node {node!r} was not passed out (still not ready)"
                    )
                elif stat == _NODE_DONE:
                    raise ValueError(f"node {node!r} was already marked done")
                else:
                    assert False, f"node {node!r}: unknown status {stat}"

            # Mark the node as processed
            nodeinfo.npredecessors = _NODE_DONE

            # Go to all the successors and reduce the number of predecessors, collecting all the ones
            # that are ready to be returned in the next get_ready() call.
            for successor in nodeinfo.successors:
                successor_info = n2i[successor]
                successor_info.npredecessors -= 1
                if successor_info.npredecessors == 0:
                    self._ready_nodes.append(successor)
            self._nfinished += 1

    def _find_cycle(self):
        n2i = self._node2info
        stack = []
        itstack = []
        seen = set()
        node2stacki = {}

        for node in n2i:
            if node in seen:
                continue

            while True:
                if node in seen:
                    # If we have seen already the node and is in the
                    # current stack we have found a cycle.
                    if node in node2stacki:
                        return stack[node2stacki[node] :] + [node]
                    # else go on to get next successor
                else:
                    seen.add(node)
                    itstack.append(iter(n2i[node].successors))
                    node2stacki[node] = len(stack)
                    stack.append(node)

                # Backtrack to the topmost stack entry with
                # at least another successor.
                while stack:
                    try:
                        node = next(itstack[-1])
                        break
                    except StopIteration:
                        del node2stacki[stack.pop()]
                        itstack.pop()
                else:
                    break
        return None

    def static_order(self):
        self.prepare()
        while self.is_active():
            node_group = self.get_ready()
            yield from node_group
            self.done(*node_group)

    def __class_getitem__(cls, item):
        return GenericAlias(cls, item)
