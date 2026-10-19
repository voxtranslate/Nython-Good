# ─── nytorch, full ───────────────────────────────────────────────────────────
# Alias of lib/nytorch_all.ny, kept because quickstart.ny imports this name.
#
# Several bundled examples (quickstart.ny, test_nytorch3.ny, test_nytorch9.ny)
# import "lib/nytorch_all.ny", but the file did not exist. Because a module that
# could not be found used to resolve silently, those examples appeared to import
# successfully and then failed later on `Tensor is not defined` — with nothing
# pointing at the missing import as the cause. All seventeen submodules were
# present the whole time; only this aggregator was absent.
#
# One aggregator: this file loads exactly what lib/nytorch.ny loads (it used
# to list a subset of the submodules in its own order, so a program's
# behaviour depended on which of the three names it imported).

import "lib/nytorch.ny"
