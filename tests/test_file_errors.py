"""Driver error translation, executing assembled code with FAT32 fault injection."""
import unittest

from py65.devices.mpu65c02 import MPU
from kernel_test_support import Memory, Symbols


class FileErrorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sym = Symbols()

    def probe(self, operation, errno=0, failure='file_open'):
        mem = Memory()
        cpu = MPU(memory=mem, pc=0x2400)
        cpu.sp, cpu.p = 0xef, 0x24
        events = self.sym.get('kernel/event.asm', 'Events')
        streams = self.sym.get('kernel/stream.asm', 'Streams')
        event, stream = 8, 0x10
        mem[events + event + 4] = stream
        mem[streams + stream + 4] = 3
        cpu.x, cpu.y = stream, event
        calls = []
        targets = {self.sym.get('f256/fat32.asm', name): name for name in
                   ('ctx_alloc', 'ctx_set', 'ctx_free', 'set_ptr', 'file_open',
                    'get_error', 'dir_read', 'dir_avail', 'terminate_name', 'led_on')}
        enque = self.sym.get('kernel/event.asm', 'enque')
        cpu.pc = self.sym.get('f256/fat32.asm', operation)
        for _ in range(20000):
            if cpu.pc == enque:
                return mem[events + event + 1], calls, mem, streams, stream
            if cpu.pc in targets:
                name = targets[cpu.pc]
                calls.append(name)
                cpu.a = errno if name == 'get_error' else 3
                if name in (failure, 'dir_avail'):
                    cpu.p &= ~cpu.CARRY
                else:
                    cpu.p |= cpu.CARRY
                # Simulate LDA's flags as well as C: the call macro's PLX
                # overwrites N/Z, so the driver must explicitly compare A.
                cpu.p = (cpu.p & ~cpu.ZERO) | (cpu.ZERO if cpu.a == 0 else 0)
                cpu.pc = cpu.stPopWord() + 1
            else:
                cpu.step()
        self.fail(f'Execution stuck at ${cpu.pc:04x}')

    def test_only_explicit_missing_file_becomes_not_found(self):
        for errno in range(16):
            with self.subTest(errno=errno):
                event, calls, mem, streams, stream = self.probe('open', errno)
                self.assertEqual(event, 0x28 if errno == 5 else 0x38)
                self.assertEqual(calls.count('ctx_free'), 1)
                self.assertLess(calls.index('get_error'), calls.index('ctx_free'))
                self.assertEqual(mem[streams + stream + 4], 0)

    def test_resource_and_context_failures_are_not_missing(self):
        for failure in ('ctx_alloc', 'ctx_set'):
            event, calls, *_ = self.probe('open', 5, failure)
            self.assertEqual(event, 0x38)
            self.assertNotIn('get_error', calls)
            self.assertEqual(calls.count('ctx_free'), int(failure == 'ctx_set'))

    def test_success_still_opens(self):
        event, calls, *_ = self.probe('open', failure=None)
        self.assertEqual(event, 0x2a)
        self.assertNotIn('get_error', calls)
        self.assertNotIn('ctx_free', calls)

    def test_directory_read_errors_do_not_become_eof(self):
        for errno in range(16):
            with self.subTest(errno=errno):
                event, calls, *_ = self.probe('read_dirent', errno, 'dir_read')
                self.assertEqual(event, 0x44 if errno == 0 else 0x48)
                self.assertEqual('dir_avail' in calls, errno == 0)


if __name__ == '__main__':
    unittest.main()
