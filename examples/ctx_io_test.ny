import io
import "examples/lib/fileio.ny"

# File with context manager (with statement)
with File("/tmp/ny_ctx.txt", "w") as f:
    f.write("written via context manager")
    print "inside with:", f

# File should be closed after with block
print "reading back:", cat("/tmp/ny_ctx.txt")
