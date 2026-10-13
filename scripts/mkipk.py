import sys


def write_ar(out_path, members):
    with open(out_path, "wb") as f:
        f.write(b"!<arch>\n")
        for name, path in members:
            with open(path, "rb") as df:
                data = df.read()
            hdr = name.encode()[:16].ljust(16)
            hdr += b"0".ljust(12)
            hdr += b"0".ljust(6)
            hdr += b"0".ljust(6)
            hdr += b"100644".ljust(8)
            hdr += str(len(data)).encode().ljust(10)
            hdr += b"`\n"
            f.write(hdr)
            f.write(data)
            if len(data) % 2:
                f.write(b"\n")


if len(sys.argv) != 5:
    sys.exit("usage: mkipk.py OUT.ipk debian-binary control.tar.gz data.tar.gz")

write_ar(sys.argv[1], [
    ("debian-binary", sys.argv[2]),
    ("control.tar.gz", sys.argv[3]),
    ("data.tar.gz", sys.argv[4]),
])