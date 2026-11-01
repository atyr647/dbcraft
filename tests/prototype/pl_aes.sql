-- AES-128-CFB8 (the Minecraft online-mode cipher) called from inside a PL/Python procedure, via the 'cryptography' library (OpenSSL).
create or replace function net.aes_bench() returns table(case_ text, mb_per_s numeric, us_per_call numeric) language plpython3u as $$
import os, time
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
key = os.urandom(16)
out = []
for label, size, calls in (("encrypt 1 KiB blobs", 1024, 20000), ("encrypt 20 KiB blobs", 20480, 2000), ("decrypt 64 B frames", 64, 100000)):
    data = os.urandom(size)
    c = Cipher(algorithms.AES(key), modes.CFB8(key)); e = c.encryptor(); d = c.decryptor()
    f = d.update if label.startswith("decrypt") else e.update
    t = time.perf_counter()
    for _ in range(calls): f(data)
    dt = time.perf_counter() - t
    out.append((label, round(size * calls / dt / 1e6, 1), round(dt / calls * 1e6, 2)))
return out
$$;
select * from net.aes_bench();
