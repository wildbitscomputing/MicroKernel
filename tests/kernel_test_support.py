"""MMU and I/O model for instruction-level kernel tests."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


class Symbols:
    def __init__(self):
        self.listing = (ROOT / 'jr.lst').read_text()

    def get(self, filename, label, occurrence=None):
        section = self.listing.split('Processing input file: ' + filename + '\n', 1)[1]
        section = section.split('Processing input file:', 1)[0]
        matches = re.findall(
            r'^[.>]([0-9a-f]{4})\t[^\n]*\t *' + re.escape(label) + r'(?=[:;\s]|$)',
            section, re.M,
        )
        if occurrence is not None:
            return int(matches[occurrence], 16)
        if len(matches) != 1:
            raise ValueError((filename, label, matches))
        return int(matches[0], 16)


class Memory:
    def __init__(self):
        self.ram = [bytearray(8192) for _ in range(256)]
        self.flash = {bank: bytearray((ROOT / 'bin' / f'{bank-0x40:02x}.bin').read_bytes())
                      for bank in range(0x7b, 0x80)}
        self.maps = [[6, 0, 0x7b, 0x7c, 0x7d, 0x7e, 6, 0x7f],
                     [6, 7, 0x7b, 0x7c, 0x7d, 0x7e, 6, 0x7f],
                     [0, 1, 2, 3, 4, 5, 6, 0x7f],
                     [0, 1, 2, 3, 4, 5, 6, 0x7f]]
        self.extensions = [[0, 0] for _ in range(4)]
        self.ctrl = self.io_ctrl = 0
        self.io = [bytearray(8192) for _ in range(4)]
        self.io[0][0x166c:0x166e] = b'\xff\xff'
        self.trace = []
        self.reassert = False

    def mapped(self, address):
        lut, slot = self.ctrl & 3, address >> 13
        bank = self.maps[lut][slot]
        if bank in self.flash:
            return self.flash[bank], address & 8191
        ext = (self.extensions[lut][slot // 4] >> (2 * (slot % 4))) & 3
        return self.ram[(bank & 63) + 64 * ext], address & 8191

    def __getitem__(self, address):
        if address == 0:
            return self.ctrl
        if address == 1:
            return self.io_ctrl
        if self.ctrl & 0x80:
            edit = (self.ctrl >> 4) & 3
            if address in (2, 3):
                return self.extensions[edit][address - 2]
            if 8 <= address < 16:
                return self.maps[edit][address - 8]
        if 0xc000 <= address < 0xe000 and not self.io_ctrl & 4:
            if address == 0xdc04 and self.io_ctrl == 0:
                self.io[0][0x1c0d] &= ~0x40  # VIA T1 acknowledge
            return self.io[self.io_ctrl & 3][address - 0xc000]
        data, offset = self.mapped(address)
        return data[offset]

    def __setitem__(self, address, value):
        value &= 255
        if address == 0:
            self.ctrl = value
            return
        if address == 1:
            self.io_ctrl = value
            return
        if self.ctrl & 0x80:
            edit = (self.ctrl >> 4) & 3
            if address in (2, 3):
                self.extensions[edit][address - 2] = value
                return
            if 8 <= address < 16:
                self.maps[edit][address - 8] = value
                return
        if 0xc000 <= address < 0xe000 and not self.io_ctrl & 4:
            if address in (0xd660, 0xd661, 0xdc0d) and self.io_ctrl == 0:
                self.io[0][address - 0xc000] &= ~value
            else:
                self.io[self.io_ctrl & 3][address - 0xc000] = value
            if address == 0xd700 and self.io_ctrl == 0:
                self.trace.append(value)
                if self.reassert and value == 1:
                    self.io[0][0x1660] |= 2
                    self.reassert = False
            return
        data, offset = self.mapped(address)
        data[offset] = value
