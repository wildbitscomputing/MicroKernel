"""Check SD drive registration through the assembled FAT32 driver init."""
import unittest

from py65.devices.mpu65c02 import MPU
from kernel_test_support import Memory, Symbols


class SDDriveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sym = Symbols()

    def registered_drives(self, machine_id):
        mem = Memory()
        cpu = MPU(memory=mem, pc=0x2400)
        cpu.sp, cpu.p = 0xef, 0x24
        mem.ctrl = 0x80
        mem.io[0][0x16a7] = machine_id
        log = self.sym.get('kernel/log.asm', 'dev_message')

        def call(filename, label, occurrence=None):
            cpu.stPushWord(0x23ff)
            cpu.pc = self.sym.get(filename, label, occurrence=occurrence)
            for _ in range(20000):
                if cpu.pc == 0x2400:
                    return
                if cpu.pc == log:
                    # Skip console output; execute the real driver init,
                    # FAT32 library init, allocation, and registration.
                    cpu.pc = cpu.stPopWord() + 1
                else:
                    cpu.step()
            self.fail(f'Execution stuck at ${cpu.pc:04x}')

        # Make one driver slot available, then initialize the token/FS tables.
        cpu.x = 8
        call('kernel/device.asm', 'free')
        call('kernel/token.asm', 'init')
        call('kernel/fs.asm', 'init')
        # The first init symbol is the library entry in the virtual header.
        call('f256/fat32.asm', 'init', occurrence=1)
        self.assertFalse(cpu.p & cpu.CARRY)
        call('kernel/fs.asm', 'get_drives')
        return cpu.a

    def test_k2_and_jr2_register_both_slots_with_all_clock_bits(self):
        for model in (0x11, 0x22):
            for clock_bits in (0, 0x40, 0x80, 0xc0):
                machine_id = model | clock_bits
                with self.subTest(machine_id=hex(machine_id)):
                    self.assertEqual(self.registered_drives(machine_id), 0b11)

    def test_other_models_register_only_primary_slot(self):
        for model in range(64):
            if model in (0x11, 0x22):
                continue
            with self.subTest(model=hex(model)):
                self.assertEqual(self.registered_drives(model), 0b1)


if __name__ == '__main__':
    unittest.main()
