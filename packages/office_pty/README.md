# office_pty

The Unix half of [pty2](https://github.com/jtmcdole/termui/tree/main/packages/pty2) 0.5.4 (MIT, see LICENSE),
adapted for the office server. pty2's fork/exec sequence (async-signal-safe FFI calls only between
`fork` and `execve`, every native resolved before forking) is kept; around it the office needed:

- the child's **pid** (pty2 has the getter commented out): the PTY host reports it, and the office
  maps listening ports to workers by it;
- the child to start the way node-pty starts it: in its own session with the PTY as its controlling
  terminal (pty2 does this), and additionally with **default signal dispositions and an empty signal
  mask** (the Dart VM ignores SIGPIPE and blocks some signals, which a child would otherwise
  inherit), and exactly the **environment it is given** (pty2 keeps only a handful of variables);
- the master **close-on-exec**, so one terminal's master never leaks into the next terminal's child
  (which would stop that terminal hanging up when it closes);
- **all output delivered before the exit** is reported, and the master closed only after its reader
  is done with it (pty2 closes it when the exit code arrives, which can drop the last output and lets
  the reader race a reused descriptor);
- non-blocking writes, so a child that stops reading its input can't stall the whole process;
- `kill()` sending SIGHUP by default, like node-pty.

Windows is not covered: the office runs terminals through `package:pty2` there.
