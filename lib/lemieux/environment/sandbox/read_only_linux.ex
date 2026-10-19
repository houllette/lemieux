defmodule Lemieux.Environment.Sandbox.ReadOnlyLinux do
  @moduledoc """
  Closes IPC paths that a read-only filesystem does not close on Linux.

  A filesystem Unix socket remains usable through a read-only bind mount.
  Network namespaces alone therefore cannot certify a script as read-only:
  connecting to a host daemon could still mutate files outside the mount.
  This small inherited seccomp filter denies sockets, ptrace and io_uring
  before executing model code. Bubblewrap supplies filesystem, PID and IPC
  isolation. Unsupported architectures or filter installation failures stop
  execution. Python 3 is the launcher; no optional unsandboxed fallback exists.

  The architecture check and inherited filter follow the kernel's
  [seccomp contract](https://docs.kernel.org/userspace-api/seccomp_filter.html).
  """

  @program ~S"""
  import ctypes, errno, os, platform, sys
  machine = platform.machine().lower()
  specs = {
      'x86_64': (0xc000003e, (41, 42, 53, 101, 321, 425, 426, 427)),
      'aarch64': (0xc00000b7, (198, 199, 203, 117, 280, 425, 426, 427)),
  }
  if machine not in specs:
      sys.exit('Read-only command filtering is unsupported on this architecture')
  arch, denied = specs[machine]
  class Insn(ctypes.Structure):
      _fields_ = [('code', ctypes.c_ushort), ('jt', ctypes.c_ubyte), ('jf', ctypes.c_ubyte), ('k', ctypes.c_uint)]
  class Program(ctypes.Structure):
      _fields_ = [('length', ctypes.c_ushort), ('filter', ctypes.POINTER(Insn))]
  # seccomp_data.arch is offset 4, nr is offset 0. Reject alternative ABIs,
  # including x32, instead of letting another syscall table bypass the policy.
  instructions = [(0x20, 0, 0, 4), (0x15, 1, 0, arch), (0x06, 0, 0, 0x80000000),
                  (0x20, 0, 0, 0), (0x35, 0, 1, 0x40000000), (0x06, 0, 0, 0x50000 | errno.EPERM)]
  for nr in denied:
      instructions += [(0x15, 0, 1, nr), (0x06, 0, 0, 0x50000 | errno.EPERM)]
  instructions += [(0x06, 0, 0, 0x7fff0000)]
  array = (Insn * len(instructions))(*(Insn(*i) for i in instructions))
  program = Program(len(instructions), array)
  libc = ctypes.CDLL(None, use_errno=True)
  if libc.prctl(38, 1, 0, 0, 0) != 0 or libc.prctl(22, 2, ctypes.byref(program), 0, 0) != 0:
      sys.exit('Could not install enforced read-only command filtering')
  os.execv(sys.argv[1], sys.argv[1:])
  """

  @doc "Arguments for an inherited, fail-closed read-only command filter."
  @spec arguments(shell :: Path.t(), command :: String.t()) :: [String.t()]
  def arguments(shell, command), do: ["python3", "-I", "-S", "-c", @program, shell, "-c", command]
end
