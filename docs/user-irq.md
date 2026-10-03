# Direct raster and VIA handlers

Applications can register a direct callback for the raster interrupt (source 1)
or VIA interrupt (source 13). The callback runs during IRQ dispatch, without
waiting for `NextEvent`. Other unclaimed interrupt sources continue to produce
IRQ events as before.

This API replaces the unimplemented `Display.DrawColumn` vector at `$FFD8`.
Older kernels return carry set from that stub and do not install a handler;
their A return value is unspecified. All other public API addresses stay unchanged.

## Registering a handler

Include `kernel/api.asm`, populate `kernel.args.irq`, and call
`kernel.IRQ.Control` at `$FFD8`. Set `operation` to `kernel.IRQ.REGISTER` (0)
or `kernel.IRQ.UNREGISTER` (1). These are stable operation IDs, independent
of the kernel's internal dispatch table. A is not an input argument.

| Argument | Meaning |
| --- | --- |
| `operation` | `kernel.IRQ.REGISTER` (0) or `kernel.IRQ.UNREGISTER` (1) |
| `source` | `kernel.IRQ.RASTER` (1) or `kernel.IRQ.VIA` (13) |
| `bank` | The resident handler's MMU bank byte |
| `extension` | RAM extension selector, 0–3; use 0 for ordinary base RAM |
| `handler` | Entry address in the `$A000–$BFFF` callback window |

`REGISTER` (0) installs one handler for the source, clears its stale
interrupt-controller pending bit, and unmasks it. Configure the peripheral and
clear its interrupt condition before registering. An existing callback must be
unregistered before replacement. A source owned by a kernel driver cannot be
claimed.

`UNREGISTER` (1) uses only `operation` and `source`. It masks the source, clears its pending
controller bit, and releases the registration. Disable the peripheral's own
interrupts before unloading the handler.

Both operations return carry clear and A=0 on success. On failure, carry is set and A
contains `IRQ.INVALID` (1: unsupported operation, source, extension, or entry address),
`IRQ.BUSY` (2: source already owned, or registration attempted in the monitor),
or `IRQ.NOT_REGISTERED` (3: unregistering an unregistered source). Failure leaves
the registration and controller unchanged. X, Y, the caller's interrupt-disable
flag, MMU control, and I/O control are preserved; other flags may change.

The application owns the handler's memory. Registration does not allocate,
copy, or lock a bank. Keep code and data resident until unregistering, and do
not use banks reserved by the kernel or monitor. The callback bank can be
independent of the application's current LUT. Extensions are supplied separately
from the MMU bank byte, not as the high byte of a linear address.

## Handler convention

The kernel maps the registered bank into LUT0 slot 5 (`$A000–$BFFF`). The handler
must be assembled for that window. Its code and private data must fit in that
single 8 KiB bank. The kernel restores the previous slot-5 mapping and extension
bits after every call.

On entry:

- A contains the IRQ source number. X and Y are unspecified.
- Interrupts are disabled, decimal mode is clear, and I/O page 0 is selected.
- The kernel's zero page and stack are active.

Return with `RTS`, with balanced stack use. A, X, Y, and arithmetic flags may be
clobbered. The handler can select other I/O pages; the dispatcher restores page 0
for the next handler and restores the interrupted I/O setting on IRQ return.

Use registers, a small amount of stack, and private data inside the callback
bank. Do not use application zero page, kernel scratch variables, or addresses
outside the callback bank for ordinary application data. Do not change MMU
registers, execute `CLI`, call kernel services, or enter the debugger with `BRK`.
A callback may interrupt an unfinished kernel operation, including FAT32 work.

The kernel clears the interrupt-controller latch before calling the handler.
The handler must acknowledge the **peripheral** itself. For VIA, inspect IFR/IER
and acknowledge every enabled cause you service; reading T1's low counter byte
acknowledges a T1 interrupt. The whole VIA source belongs to this callback,
not just one of its timers. A source that reasserts while the callback runs
remains pending for another dispatch pass or IRQ.

Keep handlers short. The dispatcher calls raster first, then VIA, before each
ordinary kernel device handler. It services each direct source at most once per
pass. Existing interrupt-disabled code, an already-running handler, and NMI
handling can delay entry; this API does not promise cycle-exact raster timing.
Applications needing longer processing should set a flag or fill a small buffer
in their resident bank, then consume it from their main loop. Protect multi-byte
shared values against interrupts.

## Monitor and program lifetime

The break monitor masks registered sources while the program is stopped. On
resume it discards stale controller requests and restores each source's previous
mask state. Missed raster/timer interrupts are not replayed. The existing monitor
resume path also clears enabled VIA interrupt flags. A Foenix/SysRq break during
a callback is deferred until execution reaches a safe application context.

Registrations are removed when a program returns through the kernel's ROM
launcher and before the kernel starts another ROM program (`RunBlock` or a
successful `RunNamed`). A loader that replaces application memory without using
these paths must unregister callbacks itself. Stopping or reprogramming the
peripheral remains the application's responsibility.

## Example

Assume the following handler image has already been copied to application-owned
RAM bank `$20`, extension 0. It is assembled at `$A000`, even if the main program
maps that bank elsewhere. A raster handler can use the same registration sequence
with `IRQ.RASTER` after configuring the raster source.

```asm
; Resident handler image, loaded into bank $20.
* = $a000
via_handler:
        lda $dc0d               ; VIA IFR
        and $dc0e               ; service only enabled causes
        and #$40                ; this example enables only T1
        beq done
        lda $dc04               ; acknowledge T1
        inc ticks               ; private data in the same bank
done:   rts
ticks:  .byte 0
```

In the main program, with I/O page 0 selected and the VIA configured:

```asm
        lda #kernel.IRQ.VIA
        sta kernel.args.irq.source
        lda #$20
        sta kernel.args.irq.bank
        stz kernel.args.irq.extension
        lda #<via_handler
        sta kernel.args.irq.handler
        lda #>via_handler
        sta kernel.args.irq.handler+1
        lda #kernel.IRQ.REGISTER
        sta kernel.args.irq.operation
        jsr kernel.IRQ.Control
        bcs registration_failed

        ; Main program continues; the handler runs on VIA interrupts.
        ; Before releasing the bank, disable the peripheral and unregister:
        lda #$7f
        sta $dc0e               ; disable all VIA interrupt enables
        lda #kernel.IRQ.VIA
        sta kernel.args.irq.source
        lda #kernel.IRQ.UNREGISTER
        sta kernel.args.irq.operation
        jsr kernel.IRQ.Control
        bcs unregister_failed
```

## Build and regression tests

`make jr.bin` rebuilds the kernel and packaged banks. The instruction-level tests
require `py65==1.2.0` and exercise the assembled kernel with separate MMU LUTs,
RAM extension fields, stacks, I/O pages, and write-one-to-clear controller latches:

```sh
python -m venv /tmp/microkernel-tests
/tmp/microkernel-tests/bin/pip install -r tests/requirements.txt
make test PYTHON=/tmp/microkernel-tests/bin/python
```

These tests do not model FPGA timing. Check raster latency/jitter, VIA peripheral
acknowledgement, monitor resume, and program changes on hardware before relying
on the callbacks for timing-sensitive work.
