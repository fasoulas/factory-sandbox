def add(a: int, b: int) -> int:
    return a + b


import subprocess


def run(cmd):
    return subprocess.run(cmd, shell=True)
