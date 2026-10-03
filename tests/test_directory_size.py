"""Exercise FAT32 directory metadata and the public ReadExt path."""
from copy import deepcopy
import unittest

from py65.devices.mpu65c02 import MPU
from kernel_test_support import Memory, Symbols


class DirectorySizeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sym = Symbols()

    def setUp(self):
        self.mem = Memory()
        self.cpu = MPU(memory=self.mem, pc=0x2345)
        self.cpu.sp, self.cpu.p = 0xef, 0x24
        self.hook = None
        self.call('kernel/event.asm', 'init')
        self.events = self.sym.get('kernel/event.asm', 'Events')
        self.ext_page = 0x0c
        self.event = 8
        self.mem[self.events + self.event + 3] = self.ext_page

    def run_to(self, target):
        for _ in range(20000):
            if self.cpu.pc == target:
                return
            if self.hook and self.hook():
                continue
            self.cpu.step()
        self.fail(f'Execution stuck at ${self.cpu.pc:04x}')

    def call(self, filename, label):
        self.cpu.stPushWord(0x23ff)
        self.cpu.pc = self.sym.get(filename, label)
        self.run_to(0x2400)

    def metadata(self):
        start = self.ext_page << 8
        return bytes(self.mem.ram[6][start:start + 10])

    def fat_details(self, size, attributes=0x20):
        self.mem.ctrl = 0x80
        # Header holds the FAT32 directory buffer address in LUT1.
        dirent = self.mem[0x8002] | (self.mem[0x8003] << 8)
        offset = dirent - 0x2000 + 256
        self.mem.ram[7][offset:offset + 9] = bytes([attributes]) + b'\x11\x22\x33\x44' + size.to_bytes(4, 'little')
        before = bytes(self.mem.ram[7])
        self.mem.extensions[0][1] = 0xb7  # nonzero slot-4 extension to restore
        maps, extensions = deepcopy(self.mem.maps), deepcopy(self.mem.extensions)
        self.cpu.x, self.cpu.y = 0x10, self.event
        self.call('f256/fat32.asm', 'copy_details')
        self.assertEqual((self.cpu.x, self.cpu.y), (0x10, self.event))
        self.assertEqual(self.mem.maps, maps)
        self.assertEqual(self.mem.extensions, extensions)
        self.assertEqual(bytes(self.mem.ram[7]), before)
        self.assertEqual(self.mem.ctrl, 0x80)
        return self.mem[self.events + self.event + 7]

    def test_exact_sizes_and_rounded_blocks_including_4gib_boundary(self):
        sizes = [0, 1, 255, 256, 257, 511, 512, 513, 65535, 65536,
                 0x7fffffff, 0xffffff00, 0xffffff01, 0xffffffff]
        for size in sizes:
            with self.subTest(size=size):
                self.setUp()
                flags = self.fat_details(size)
                data = self.metadata()
                self.assertEqual(flags, 0xa0)
                self.assertEqual(int.from_bytes(data[:6], 'little'), (size + 255) // 256)
                self.assertEqual(int.from_bytes(data[6:10], 'little'), size)

    def test_preserves_attributes_and_does_not_claim_directory_byte_size(self):
        for attributes in (0x01, 0x02, 0x04, 0x20, 0x27, 0x08, 0x10, 0x16):
            with self.subTest(attributes=attributes):
                self.setUp()
                flags = self.fat_details(12345, attributes)
                self.assertEqual(flags & 0x3f, attributes)
                self.assertEqual(bool(flags & 0x80), not bool(attributes & 0x18))
                if attributes & 0x18:
                    self.assertEqual(self.metadata()[6:], b'\0' * 4)

    def test_readext_exposes_new_size_and_keeps_legacy_prefix(self):
        self.fat_details(12345)
        expected = self.metadata()
        cur_event = self.sym.get('kernel/kernel.asm', 'cur_event')
        self.mem.ram[6][cur_event] = self.event
        self.mem.ctrl, self.mem.io_ctrl = 0xb3, 2
        for count in (2, 3, 6, 10):
            with self.subTest(count=count):
                for index in range(12):
                    self.mem[0x3000 + index] = 0xcc
                self.mem[0xfb], self.mem[0xfc], self.mem[0xfd] = 0, 0x30, count
                self.cpu.x, self.cpu.y = 0x81, 0x97
                self.cpu.stPushWord(0x23ff)
                self.cpu.pc = 0xff08  # kernel.ReadExt
                self.run_to(0x2400)
                self.assertEqual(bytes(self.mem[0x3000 + i] for i in range(count)), expected[:count])
                self.assertEqual(self.mem[0x3000 + count], 0xcc)
                self.assertEqual((self.cpu.x, self.cpu.y, self.mem.ctrl, self.mem.io_ctrl),
                                 (0x81, 0x97, 0xb3, 2))

    def allocate_read(self, driver=None):
        # Dirty the reusable page pool, then use the real Directory.Read API.
        self.mem.ram[6][0xc00:0x2000] = b'\xcc' * 0x1400
        self.cpu.a = 0x0c
        self.call('kernel/pages.asm', 'init')
        streams = self.sym.get('kernel/stream.asm', 'Streams')
        self.mem[streams + 0x10 + 1] = 8
        devices = self.sym.get('kernel/device.asm', 'Devices')
        target = driver if driver is not None else 0xfd00
        self.mem[devices + 260 + 8], self.mem[devices + 260 + 9] = target & 255, target >> 8
        self.mem[streams + 0x10 + 5] = 6  # FAT32 directory-entry read state
        self.mem.flash[0x7f][0x1d00] = 0x60  # stand-in driver's send entry
        self.mem.ctrl = 0xb3
        self.mem[0xf3], self.mem[0xf4] = 0x10, 0
        self.cpu.stPushWord(0x23ff)
        self.cpu.pc = 0xff7c  # kernel.Directory.Read
        self.run_to(0x2400)
        self.mem.ctrl = 0
        self.event = self.cpu.y
        self.ext_page = self.mem[self.events + self.event + 3]

    def test_public_directory_read_event_and_readext_with_fat32_driver(self):
        # Supply one FAT32 directory entry, bypassing only card I/O/context
        # setup. Run the real filesystem dispatch, driver, and event APIs.
        for label in ('ctx_set', 'dir_read'):
            address = self.sym.get('f256/fat32.asm', label)
            self.mem.flash[0x7d][address - 0x8000:address - 0x8000 + 2] = b'\x38\x60'
        dirent = self.mem[0x8002] | (self.mem[0x8003] << 8)
        offset = dirent - 0x2000
        self.mem.ram[7][offset:offset + 5] = b'TEST\0'
        self.mem.ram[7][offset + 256:offset + 265] = b'\x20' + b'\0' * 4 + (12345).to_bytes(4, 'little')
        self.allocate_read(driver=self.sym.get('f256/fat32.asm', 'dev_send'))
        self.mem.ctrl, self.mem.io_ctrl = 0xb3, 2
        self.mem[0xf0], self.mem[0xf1] = 0, 0x31
        self.cpu.stPushWord(0x23ff)
        self.cpu.pc = 0xff00  # NextEvent
        self.run_to(0x2400)
        self.assertFalse(self.cpu.p & self.cpu.CARRY)
        self.assertEqual(self.mem[0x3105], 4)  # filename length
        self.assertEqual(self.mem[0x3106], 0xa0)  # archive + exact size
        self.mem[0xfb], self.mem[0xfc], self.mem[0xfd] = 0, 0x30, 10
        self.cpu.stPushWord(0x23ff)
        self.cpu.pc = 0xff08  # ReadExt
        self.run_to(0x2400)
        result = bytes(self.mem[0x3000 + i] for i in range(10))
        self.assertEqual(int.from_bytes(result[:6], 'little'), 49)
        self.assertEqual(int.from_bytes(result[6:], 'little'), 12345)

    def test_reused_extended_page_is_initialized_before_driver_dispatch(self):
        self.allocate_read()
        self.assertEqual(self.metadata(), b'\0' * 10)
        # The rest of the existing page need not be cleared or allocated again.
        self.assertEqual(self.mem.ram[6][(self.ext_page << 8) + 10], 0xcc)
        self.assertEqual(self.mem[self.events + self.event + 7], 0)

    def test_iec_directory_keeps_block_count_without_fabricated_exact_size(self):
        self.allocate_read()
        incoming = iter(b'\x01\x08\x34\x12 "TEST" PRG\x00')
        iecin = self.sym.get('f256/iec.asm', 'IECIN')
        def feed_bus():
            if self.cpu.pc != iecin:
                return False
            self.cpu.a = next(incoming)
            self.cpu.p &= ~(self.cpu.CARRY | self.cpu.OVERFLOW | self.cpu.ZERO | self.cpu.NEGATIVE)
            self.cpu.p |= self.cpu.ZERO if self.cpu.a == 0 else self.cpu.a & self.cpu.NEGATIVE
            self.cpu.pc = (self.cpu.stPopWord() + 1) & 65535
            return True
        self.hook = feed_bus
        self.cpu.y = self.event
        self.call('hardware/iec.asm', 'read_dirent')
        self.assertEqual(self.metadata(), b'\x34\x12' + b'\0' * 8)
        self.assertEqual(self.mem[self.events + self.event + 7] & 0x80, 0)
        self.assertEqual(self.mem[self.events + self.event + 6], 4)
        self.assertEqual(list(incoming), [])


if __name__ == '__main__':
    unittest.main()
