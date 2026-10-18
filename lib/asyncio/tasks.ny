# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/asyncio/tasks.ny - asyncio.tasks: tasks and the functions over them
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (Task, create_task, FIRST_COMPLETED, FIRST_EXCEPTION, ALL_COMPLETED, wait, wait_for, as_completed, sleep, gather, shield, ensure_future, run_coroutine_threadsafe, current_task, all_tasks, create_eager_task_factory, eager_task_factory, to_thread)
