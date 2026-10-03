"""Exercise monitor copying, high-RAM mapping, and return to the application."""
from copy import deepcopy
import unittest

from py65.devices.mpu65c02 import MPU
from kernel_test_support import Memory


class MonitorMemoryTests(unittest.TestCase):
    def setUp(self):
        self.mem = Memory()
        self.cpu = MPU(memory=self.mem, pc=0x2345)
        self.cpu.sp, self.cpu.p = 0xef, 0x21
        self.mem.ctrl = 0xb3
        self.mem.io[0][0x16a7] = 0x22
        self.mem.io[0][0x16b6] = 0x80
        self.mem.flash[0x4a] = bytearray([0x5a] * 8192)
        self.mem.flash[0x4b] = bytearray([0xa5] * 8192)
        # Return the extension context using MON's ABI.
        stub = bytes.fromhex('a9 b3 85 00 a6 02 ad 08 80 60')
        self.mem.flash[0x4a][0x100:0x100 + len(stub)] = stub
        for bank in (0x3e, 0x3f):
            self.mem.ram[bank][:] = b'\xcc' * 8192

    def run_to(self, target):
        for _ in range(200000):
            if self.cpu.pc == target:
                return
            self.cpu.step()
        self.fail(f'Execution stuck at ${self.cpu.pc:04x}')

    def test_copies_to_high_ram_and_restores_application_mapping(self):
        self.mem.extensions[3] = [0x40, 0x65]
        self.mem.maps[3][4:6] = [0x14, 0x15]
        maps, extensions = deepcopy(self.mem.maps), deepcopy(self.mem.extensions)
        self.cpu.a, self.cpu.x, self.cpu.y = 0x51, 0x82, 0x97
        self.cpu.nmi()
        self.run_to(0x8100)
        self.assertEqual(self.mem.maps[3][4:6], [0x3e, 0x3f])
        self.assertEqual(self.mem.extensions[3][1], 0x6f)
        # The copied header contains the victim's source/map context.
        self.assertEqual(self.mem.ram[0xfe][:7], self.mem.flash[0x4a][:7])
        self.assertEqual(self.mem.ram[0xfe][7:10], b'\x00\x65\x14')
        self.assertEqual(self.mem.ram[0xfe][10:], self.mem.flash[0x4a][10:])
        self.assertEqual(self.mem.ram[0xff], self.mem.flash[0x4b])
        for bank in (0x3e, 0x3f):
            self.assertEqual(self.mem.ram[bank], b'\xcc' * 8192)
        self.run_to(0x2345)
        self.assertEqual(self.mem.maps, maps)
        self.assertEqual(self.mem.extensions, extensions)
        self.assertEqual((self.cpu.a, self.cpu.x, self.cpu.y, self.cpu.sp),
                         (0x51, 0x82, 0x97, 0xef))
        self.assertEqual(self.mem.ctrl, 0xb3)

    def test_self_guard_matches_high_ram_not_released_low_ram(self):
        for extension in (0, 3):
            with self.subTest(extension=extension):
                self.setUp()
                self.mem.maps[3][5] = 0x3f
                self.mem.extensions[3][1] = extension << 2
                self.cpu.nmi()
                if extension == 3:
                    self.run_to(0x2345)
                    self.assertEqual(self.mem.ram[0xfe], b'\0' * 8192)
                else:
                    self.run_to(0x8100)
                    self.assertEqual(self.mem.ram[0xff], self.mem.flash[0x4b])
                    self.run_to(0x2345)
                self.assertEqual(self.mem.extensions[3][1], extension << 2)


if __name__ == '__main__':
    unittest.main()
