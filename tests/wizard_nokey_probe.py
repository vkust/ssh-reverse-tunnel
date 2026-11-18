"""Drive the add-tunnel wizard in a pty, with a key that is NOT installed on the VPS.

Answers: install key? -> n (we refuse), save and start? -> y.
Prints the wizard output from the key check onward. Env: SRT, SRT_CONF_DIR, NEWKEY.
"""
import os
import pty
import re
import select
import sys
import time

SRT = os.environ["SRT"]
KEY = os.environ["NEWKEY"]
ENV = dict(os.environ, TERM="xterm")

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(SRT, [SRT, "menu"], ENV)

out = b""


def drain(t):
    global out
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                out += os.read(fd, 65536)
            except OSError:
                return


def send(k, t=2.0):
    os.write(fd, k.encode())
    drain(t)


drain(1.5)
send("1\n")            # главное меню -> туннели
send("2\n")            # туннели -> добавить
send("nokey\n")        # имя
send("37.46.17.61\n")  # адрес VPS
send("root\n")         # пользователь
send("22\n")           # SSH-порт VPS
send("10.0.89.52:3128\n")  # прокси
send("127.0.0.1\n")    # цель
send("22\n")           # порт цели
send("2228\n")         # порт на VPS
send("1\n")            # 0.0.0.0
send(KEY + "\n")       # ключ (уже существует, не установлен на VPS)
drain(4.0)             # проверка входа по ключу
send("n\n", 3.0)       # установить ключ на VPS? -> нет
send("y\n", 6.0)       # сохранить и запустить? -> да
drain(10.0)            # дать сервису попытаться подключиться
try:
    os.kill(pid, 9)
except OSError:
    pass

txt = re.sub(rb"\x1b\[[0-9;]*[A-Za-z]", b"", out).decode(errors="replace")
i = txt.find("вход на VPS")
sys.stdout.write(txt[max(0, i - 60):] if i >= 0 else "key check not printed\n" + txt[-1500:])
