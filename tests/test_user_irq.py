"""Execute the assembled kernel with MMU, W1C IRQ latches, and separate stacks.

Run after `make jr.bin`: python -m unittest discover -s tests -v
Requires py65==1.2.0. This models 65C02 execution, not FPGA timing.
"""
from copy import deepcopy
import unittest

from py65.devices.mpu65c02 import MPU
from kernel_test_support import Memory, Symbols

class UserIRQTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sym = Symbols()

    def setUp(self):
        self.mem = Memory()
        self.cpu = MPU(memory=self.mem, pc=0x2345)
        self.cpu.sp = 0xef
        self.on_step = None
        self.call('f256/user_irq.asm', 'init')
        self.call('kernel/event.asm', 'init')
        # Generic IRQ events use the reserved device's data vector.
        dummy = self.sym.get('f256/irq.asm', '_dummy')
        devices = self.sym.get('kernel/device.asm', 'Devices')
        self.mem[devices], self.mem[devices + 1] = dummy & 255, dummy >> 8
        self.mem.ctrl = 0xb3

    def run_to(self, target, limit=20000):
        for _ in range(limit):
            if self.cpu.pc == target:
                return
            if self.on_step:
                self.on_step()
            self.cpu.step()
        self.fail(f'Execution stuck at ${self.cpu.pc:04x}, wanted ${target:04x}')

    def call(self, filename, label):
        self.cpu.stPushWord(0x23ff)
        self.cpu.pc = self.sym.get(filename, label)
        self.run_to(0x2400)

    def api(self, source, bank=0x20, extension=0, handler=0xa000, unregister=False,
            operation=None):
        if operation is None:
            operation = 1 if unregister else 0
        for offset, value in enumerate([operation, source, bank, extension,
                                        handler & 255, handler >> 8]):
            self.mem[0xf3 + offset] = value
        self.cpu.a = 0xa5  # Operation comes from the argument block, not A.
        expected = (self.cpu.x, self.cpu.y, self.cpu.sp, self.cpu.p & self.cpu.INTERRUPT,
                    self.mem.ctrl, self.mem.io_ctrl)
        self.cpu.stPushWord(0x23ff)
        self.cpu.pc = 0xffd8  # kernel.IRQ.Control
        self.run_to(0x2400)
        self.assertEqual((self.cpu.x, self.cpu.y, self.cpu.sp,
                          self.cpu.p & self.cpu.INTERRUPT, self.mem.ctrl, self.mem.io_ctrl),
                         expected)
        return self.cpu.a, bool(self.cpu.p & self.cpu.CARRY)

    def callback(self, bank=0x20, extension=0):
        # Record source, acknowledge VIA T1, count calls in resident data;
        # clobber registers, decimal flag and I/O page to test restoration.
        code = bytes.fromhex('8d 00 d7 ad 04 dc ee 00 a1 a9 02 85 01 a2 cd a0 ef f8 60')
        self.mem.ram[bank + 64 * extension][:len(code)] = code

    def irq(self, lut=None, io=2, source0=0, source1=0):
        if lut is not None:
            self.mem.ctrl = lut
        self.mem.io_ctrl = io
        self.mem.io[0][0x1660] |= source0
        self.mem.io[0][0x1661] |= source1
        self.cpu.pc = 0x2345
        self.cpu.a, self.cpu.x, self.cpu.y = 0x42, 0x81, 0x97
        self.cpu.p = 0x21
        expected = (self.cpu.a, self.cpu.x, self.cpu.y, self.cpu.sp,
                    self.mem.ctrl, self.mem.io_ctrl)
        self.cpu.irq()
        self.run_to(0x2345)
        actual = (self.cpu.a, self.cpu.x, self.cpu.y, self.cpu.sp,
                  self.mem.ctrl, self.mem.io_ctrl)
        self.assertEqual(actual, expected)
        self.assertFalse(self.cpu.p & (self.cpu.INTERRUPT | self.cpu.DECIMAL))

    def test_registration_abi_and_duplicate(self):
        self.mem.io_ctrl = 3
        self.cpu.x, self.cpu.sp, self.cpu.p = 0x82, 0xe0, 0x24
        self.assertEqual(self.api(1), (0, False))
        self.assertEqual((self.mem.ctrl, self.mem.io_ctrl, self.cpu.x, self.cpu.sp),
                         (0xb3, 3, 0x82, 0xe0))
        self.assertTrue(self.cpu.p & self.cpu.INTERRUPT)
        self.assertEqual(self.mem.io[0][0x166c], 0xfd)
        self.assertEqual(self.api(1), (2, True))

    def test_invalid_registration_has_no_side_effects(self):
        for source in (0, 2, 4, 12, 14, 255):
            with self.subTest(source=source):
                self.assertEqual(self.api(source), (1, True))
        for entry in (0, 0x9fff, 0xc000, 0xffff):
            self.assertEqual(self.api(1, handler=entry), (1, True))
        self.assertEqual(self.api(1, extension=4), (1, True))
        self.assertEqual(self.mem.io[0][0x166c:0x166e], b'\xff\xff')

    def test_unknown_control_operations_leave_existing_handlers_unchanged(self):
        self.callback()
        self.assertEqual(self.api(1), (0, False))
        controller = bytes(self.mem.io[0])
        self.cpu.x, self.cpu.y, self.cpu.p = 0x82, 0x97, 0x20
        for operation in range(2, 256):
            with self.subTest(operation=operation):
                self.assertEqual(self.api(1, operation=operation), (1, True))
                self.assertEqual(bytes(self.mem.io[0]), controller)
        self.irq(source0=2)
        self.assertEqual(self.mem.trace, [1])
        self.assertEqual(self.api(1, unregister=True), (0, False))

    def test_kernel_owned_and_monitor_registration_rejected(self):
        irqs = self.sym.get('f256/irq.asm', 'irqs')
        self.mem.ram[6][irqs + 13] = 8
        self.assertEqual(self.api(13), (2, True))
        guard = self.sym.get('f256/jr.asm', 'nmi_in_progress')
        self.mem.ram[6][guard] = 1
        self.assertEqual(self.api(1), (2, True))

    def test_callback_restores_mappings_in_application_and_kernel(self):
        self.callback(extension=2)
        self.assertEqual(self.api(13, extension=2), (0, False))
        self.mem.maps[0][5] = 0x12  # interrupted kernel borrowed a RAM window
        self.mem.extensions[0] = [0x40, 0xbf]
        self.mem.extensions[3] = [0x40, 0xa5]
        maps, extensions = deepcopy(self.mem.maps), deepcopy(self.mem.extensions)
        for lut in (0xb3, 0, 1, 0x80, 0x91):
            with self.subTest(lut=lut):
                self.mem.io[0][0x1c0d] = 0x40
                self.irq(lut=lut, source1=0x20)
                self.assertEqual(self.mem.maps, maps)
                self.assertEqual(self.mem.extensions, extensions)
                self.assertEqual(self.mem.io[0][0x1c0d], 0)
        self.assertEqual(self.mem.trace, [13] * 5)
        self.assertEqual(self.mem.ram[0xa0][0x100], 5)
        self.assertEqual(self.mem.ram[0][0xf2], 0)  # no queued events

    def test_raster_then_via_before_frame_driver(self):
        self.callback()
        self.callback(bank=0x21)
        self.api(1)
        self.api(13, bank=0x21)
        # A stand-in ordinary frame driver records 99 and returns.
        self.mem.flash[0x7f][0x1d00:0x1d06] = bytes.fromhex('a9 63 8d 00 d7 60')
        irqs = self.sym.get('f256/irq.asm', 'irqs')
        devices = self.sym.get('kernel/device.asm', 'Devices')
        self.mem.ram[6][irqs] = 8
        self.mem.ram[6][devices + 8:devices + 10] = b'\x00\xfd'
        self.mem.io[0][0x166c] &= ~1
        self.irq(source0=3, source1=0x20)
        self.assertEqual(self.mem.trace, [1, 13, 99])

    def test_reasserted_callback_does_not_become_generic_event(self):
        self.callback()
        self.api(1)
        self.mem.reassert = True
        self.irq(source0=2)
        self.assertEqual(self.mem.trace, [1])
        self.assertEqual(self.mem.io[0][0x1660], 2)
        self.assertEqual(self.mem.ram[0][0xf2], 0)
        self.irq()
        self.assertEqual(self.mem.trace, [1, 1])

    def test_registered_but_masked_source_stays_pending(self):
        self.callback()
        self.api(1)
        self.mem.io[0][0x166c] |= 2
        self.irq(source0=2)
        self.assertEqual(self.mem.trace, [])
        self.assertEqual(self.mem.io[0][0x1660], 2)

    def test_unregistered_source_still_queues_events(self):
        self.mem.io[0][0x166d] &= ~0x20
        self.irq(source1=0x20)
        self.assertEqual(self.mem.ram[0][0xf2], 255)
        self.assertEqual(self.mem.io[0][0x1661], 0)

    def test_unregister_masks_only_owned_source(self):
        self.api(1)
        self.mem.io[0][0x166c] = 0xf0
        self.mem.io[0][0x1660] = 0x82
        self.assertEqual(self.api(1, unregister=True), (0, False))
        self.assertEqual(self.mem.io[0][0x166c], 0xf2)
        self.assertEqual(self.mem.io[0][0x1660], 0x80)
        self.assertEqual(self.api(1, unregister=True), (3, True))
        self.assertEqual(self.api(255, unregister=True), (1, True))
        self.assertEqual(self.api(1), (0, False))

    def test_monitor_pause_restores_only_owned_mask_bits(self):
        self.callback()
        self.api(1)
        self.api(13)
        self.mem.ctrl = 0
        self.mem.io[0][0x166d] |= 0x20  # VIA was deliberately masked
        self.call('f256/user_irq.asm', 'suspend')
        self.assertEqual(self.mem.io[0][0x166c:0x166e], b'\xff\xff')
        self.irq(source0=2, source1=0x20)
        self.assertEqual(self.mem.trace, [])
        self.mem.io[0][0x166c] &= ~4  # unrelated change made in the monitor
        self.call('f256/user_irq.asm', 'resume')
        self.assertEqual(self.mem.io[0][0x166c:0x166e], b'\xf9\xff')
        self.assertEqual(self.mem.io[0][0x1660:0x1662], b'\x00\x00')
        self.irq(source0=2, source1=0x20)
        self.assertEqual(self.mem.trace, [1])

    def test_program_cleanup_preserves_caller_and_releases_handlers(self):
        self.api(1)
        self.api(13)
        self.mem.ctrl, self.mem.io_ctrl = 0x80, 2
        self.cpu.a, self.cpu.x = 0x51, 0x4a
        self.call('f256/user_irq.asm', 'clear')
        self.assertEqual((self.cpu.a, self.cpu.x, self.mem.ctrl, self.mem.io_ctrl),
                         (0x51, 0x4a, 0x80, 2))
        self.assertEqual(self.mem.io[0][0x166c:0x166e], b'\xff\xff')
        self.mem.ctrl = 0xb3
        self.assertEqual(self.api(1), (0, False))
        self.assertEqual(self.api(13), (0, False))

    def test_runblock_and_runnamed_clear_before_starting_new_program(self):
        for vector in (0xff14, 0xff18):
            with self.subTest(vector=vector):
                self.setUp()
                self.api(1)
                self.api(13)
                self.mem.flash[0x41] = bytearray(8192)
                self.mem.flash[0x41][:15] = bytes.fromhex('f2 56 01 01 00 21 00 00 00 00') + b'demo\0'
                self.mem[0xf3] = 0x41
                for i, value in enumerate(b'demo\0'):
                    self.mem[0x2200 + i] = value
                self.mem[0xfb], self.mem[0xfc] = 0, 0x22
                self.cpu.pc = vector
                self.run_to(self.sym.get('f256/flash.asm', '_start'))
                self.assertEqual(self.mem.io[0][0x166c:0x166e], b'\xff\xff')
                self.assertEqual(self.api(1, unregister=True), (3, True))
                self.assertEqual(self.api(13, unregister=True), (3, True))

    def test_monitor_entry_and_return_pause_and_restore_callbacks(self):
        self.api(1)
        self.api(13)
        self.mem.flash[0x4a] = bytearray(8192)
        self.mem.flash[0x4b] = bytearray(8192)
        # A tiny monitor substitute returns the extension context using MON's
        # actual ABI. Run the kernel's real copy, entry, and resume paths.
        stub = bytes.fromhex('a9 b3 85 00 a6 02 ad 08 80 60')
        self.mem.flash[0x4a][0x100:0x100 + len(stub)] = stub
        self.mem.io[0][0x16a7] = 0x22
        self.mem.io[0][0x16b6] = 0x80
        self.mem.io[0][0x1c0d] = 0x40
        self.mem.io[0][0x1c0e] = 0x40
        self.mem.io[0][0x1660], self.mem.io[0][0x1661] = 2, 0x20
        self.cpu.pc, self.cpu.p = 0x2345, 0x21
        self.mem.io_ctrl = 0
        maps, extensions = deepcopy(self.mem.maps), deepcopy(self.mem.extensions)
        self.cpu.nmi()
        self.run_to(0x8100, limit=200000)
        self.assertEqual(self.mem.io[0][0x166c:0x166e], b'\xff\xff')
        self.run_to(0x2345)
        self.assertEqual(self.mem.io[0][0x166c:0x166e], b'\xfd\xdf')
        self.assertEqual(self.mem.io[0][0x1660:0x1662], b'\x00\x00')
        self.assertEqual(self.mem.io[0][0x1c0d] & 0x40, 0)
        self.assertEqual(self.mem.maps, maps)
        self.assertEqual(self.mem.extensions, extensions)
        self.assertEqual(self.mem.ctrl, 0xb3)

    def test_key_break_inside_callback_is_deferred(self):
        self.callback()
        self.api(13)
        # JR2 uses the explicit SysRq NMI cause. Inject it at callback entry.
        self.mem.io[0][0x16a7] = 0x22
        self.mem.io[0][0x16b6] = 0x80
        def interrupt():
            if self.cpu.pc == 0xa000:
                self.on_step = None
                self.cpu.nmi()
        self.on_step = interrupt
        self.irq(source1=0x20)
        pending = self.sym.get('f256/jr.asm', 'nmi_pending')
        self.assertEqual(self.mem.ram[6][pending], 1)
        self.assertEqual(self.mem.trace, [13])


if __name__ == '__main__':
    unittest.main()
