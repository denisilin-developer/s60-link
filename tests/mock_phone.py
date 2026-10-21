import os, shutil, socket, struct, sys, threading, time

ROOT = os.path.abspath(sys.argv[1])
SMS = [
    [101, 'in', 1760860000, 0, '+380501112233', 'Мама', 'Привет! Как дела?\nПозвони вечером'],
    [102, 'sent', 1760860300, 0, '+380501112233', 'Мама', 'Все хорошо, позвоню'],
    [103, 'in', 1760870000, 1, '+380501112233', 'Мама', 'Ок 👍'],
    [104, 'in', 1760800000, 1, 'Kyivstar', 'Kyivstar', 'Ваш баланс: 125.40 грн'],
    [105, 'sent', 1760700000, 0, '0671234567', '', 'Tab\there and a backslash \\ test'],
]
NEXT_ID = [200]


def esc(t):
    return t.replace('\\', '\\\\').replace('\n', '\\n').replace('\t', '\\t')


def unesc(t):
    out, i = '', 0
    while i < len(t):
        if t[i] == '\\' and i + 1 < len(t):
            out += {'n': '\n', 't': '\t'}.get(t[i + 1], t[i + 1])
            i += 2
        else:
            out += t[i]
            i += 1
    return out

PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5715


def local(path):
    drive, _, rest = path.partition(':')
    parts = [p for p in rest.replace('\\', '/').split('/') if p not in ('', '.', '..')]
    return os.path.join(ROOT, drive.upper(), *parts)


def bmp(w=320, h=240):
    stride = (w * 3 + 3) & ~3
    rows = b''.join(bytes(b for x in range(w) for b in (x % 256, y % 256, 128)) + b'\0' * (stride - w * 3)
                    for y in range(h - 1, -1, -1))
    head = b'BM' + struct.pack('<IHHIIiiHHIIiiII', 54 + len(rows), 0, 0, 54, 40, w, h, 1, 24, 0, len(rows), 2835, 2835, 0, 0)
    return head + rows


class Client:
    def __init__(self, sock):
        self.s, self.buf = sock, b''

    def read_line(self):
        while b'\n' not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b'\n')
        return line.decode()

    def read_exact(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def ok(self, body=b''):
        self.s.sendall(b'OK\t%d\n' % len(body) + body)

    def err(self, what):
        self.s.sendall(('ERR\t%s (-1)\n' % what).encode())

    def serve(self):
        while True:
            args = self.read_line().split('\t')
            cmd = args[0]
            try:
                self.handle(cmd, args)
            except OSError as e:
                self.err(str(e))

    def handle(self, cmd, a):
        if cmd == 'HELLO':
            self.ok(b'S60Link\t1\tV 091.004|04-09-10|RM-530|(c) Nokia (mock)')
        elif cmd == 'PING':
            self.ok()
        elif cmd == 'DRIVES':
            self.ok(b''.join(b'%s\t%d\t%d\t%s\t0\n' % (d.encode(), 50_000_000, 100_000_000, n)
                             for d, n in (('C', b'Phone'), ('E', b'2GB'))))
        elif cmd == 'LS':
            p = local(a[1])
            out = b''
            for name in sorted(os.listdir(p), key=lambda n: (not os.path.isdir(os.path.join(p, n)), n.lower())):
                st = os.stat(os.path.join(p, name))
                out += b'%s\t%d\t%d\t%s\n' % (b'd' if os.path.isdir(os.path.join(p, name)) else b'f',
                                             0 if os.path.isdir(os.path.join(p, name)) else st.st_size,
                                             int(st.st_mtime), name.encode())
            self.ok(out)
        elif cmd == 'GET':
            self.ok(open(local(a[1]), 'rb').read())
        elif cmd == 'PUT':
            data = self.read_exact(int(a[2]))
            open(local(a[1]), 'wb').write(data)
            self.ok()
        elif cmd == 'MKDIR':
            os.makedirs(local(a[1]), exist_ok=True)
            self.ok()
        elif cmd == 'DEL':
            p = local(a[1])
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
            self.ok()
        elif cmd == 'REN':
            os.rename(local(a[1]), local(a[2]))
            self.ok()
        elif cmd == 'INSTALL':
            print('install requested:', a[1], flush=True)
            self.ok()
        elif cmd == 'SMSLIST':
            time.sleep(0.3)
            self.ok(''.join('%d\t%s\t%d\t%d\t%s\t%s\t%s\n' % (m[0], m[1], m[2], m[3], esc(m[4]), esc(m[5]), esc(m[6]))
                            for m in SMS).encode())
        elif cmd == 'SMSSEND':
            NEXT_ID[0] += 1
            SMS.append([NEXT_ID[0], 'sent', int(time.time()), 0, a[1], '', unesc(a[2])])
            self.ok()
        elif cmd == 'SMSREAD':
            for m in SMS:
                if m[0] == int(a[1]):
                    m[3] = 0
            self.ok()
        elif cmd == 'SMSDEL':
            SMS[:] = [m for m in SMS if m[0] != int(a[1])]
            self.ok()
        elif cmd == 'SHOT':
            self.ok(bmp())
        else:
            self.err('unknown command')


def run():
    for d in ('C', 'E'):
        os.makedirs(os.path.join(ROOT, d), exist_ok=True)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', PORT))
    srv.listen(1)
    print('mock phone on port', PORT, flush=True)
    while True:
        sock, _ = srv.accept()
        threading.Thread(target=lambda: _serve(sock), daemon=True).start()


def _serve(sock):
    try:
        Client(sock).serve()
    except (EOFError, ConnectionError):
        pass
    finally:
        sock.close()


if __name__ == '__main__':
    run()
