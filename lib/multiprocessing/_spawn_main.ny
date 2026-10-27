# lib/multiprocessing/_spawn_main.ny - the program a spawned multiprocessing
# child runs (round 80; see lib/multiprocessing/spawn.ny):
#
#     nython _spawn_main.ny ADDRESS TOKEN
#
# ADDRESS is the parent's object server (a socket path, or host:port), TOKEN
# names what the parent left there for this child.
import sys
from multiprocessing import spawn as _ny_mp_spawn
sys.exit(_ny_mp_spawn._main(sys.argv))
